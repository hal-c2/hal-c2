defmodule HalC2.Steps.Orchestration.AutoSettle do
  @moduledoc """
  Steps for `features/node/orchestration/auto-settle.feature`. The settlement
  service starts, without its timer, only once a step sweeps (or changes the
  settings), so the Given steps build a thread without a change-driven sweep
  settling it halfway through.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Orchestration.Settlement
  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @hour 60 * 60 * 1_000

  step "auto-settle after {int} days and auto-settle on merge are on",
       %{args: [days]} = context do
    Node.ensure(HalC2.Settings)

    write_settings(context, %{
      "sidebarAutoSettleAfterDays" => days,
      "sidebarAutoSettleOnMerge" => true
    })
  end

  step "auto-settle on merge is off", context do
    write_settings(context, %{"sidebarAutoSettleOnMerge" => false})
  end

  step "project {string} sets auto-settle after {int} day(s)", %{args: [title, days]} = context do
    id = World.project(context, title).id

    write_settings(context, %{
      "projectSettingsOverrides" => %{id => %{"sidebarAutoSettleAfterDays" => days}}
    })
  end

  step "the user changes auto-settle to {int} day(s)", %{args: [days]} = context do
    Node.ensure({Settlement, interval: nil})
    write_settings(context, %{"sidebarAutoSettleAfterDays" => days})
  end

  step "thread {string} finished its last turn {int} days ago",
       %{args: [thread, days]} = context do
    finished(context, thread, -World.days(days) - 60_000)
  end

  step "thread {string} links a pull request that merged after the user last worked in it",
       %{args: [thread]} = context do
    context |> worked(thread, -@hour) |> link(thread) |> sync(thread, "merged", 0)
  end

  step "thread {string} links a pull request that closed after the user last worked in it",
       %{args: [thread]} = context do
    context |> worked(thread, -@hour) |> link(thread) |> sync(thread, "closed", 0)
  end

  step "thread {string} links a pull request that merged an hour ago",
       %{args: [thread]} = context do
    context
    |> ensure_thread(thread)
    |> World.patch_thread(thread, %{"createdAt" => World.iso_from_now(-2 * @hour)})
    |> link(thread)
    |> sync(thread, "merged", -@hour)
  end

  step "thread {string} links a pull request that merged yesterday",
       %{args: [thread]} = context do
    context
    |> ensure_thread(thread)
    |> World.patch_thread(thread, %{"createdAt" => World.iso_from_now(-World.days(2))})
    |> link(thread)
    |> sync(thread, "merged", -World.days(1))
  end

  step "the user sent a message in {string} today", %{args: [thread]} = context do
    World.add_message(context, thread, "user", "One more change", World.iso_from_now(-@hour))
  end

  step "thread {string} links an open pull request", %{args: [thread]} = context do
    context |> ensure_thread(thread) |> link(thread) |> sync(thread, "open", 0)
  end

  # Idle long enough to settle, so only the unsynced link holds it back.
  step "thread {string} links a pull request whose state is not known yet",
       %{args: [thread]} = context do
    context |> finished(thread, -World.days(10)) |> link(thread)
  end

  # Shared with threads, thread-organization and pull-request-links. As a Given it
  # archives the thread, creating it (named as its id) when the scenario has none;
  # otherwise it asserts.
  step "thread {string} is archived", %{args: [thread]} = context do
    if World.given?(context) do
      context =
        context
        |> Map.put(:thread, thread)
        |> Map.update(:threads, %{thread => thread}, &Map.put_new(&1, thread, thread))

      context =
        if World.thread(context, thread), do: context, else: World.named_thread(context, thread)

      update(context, thread, "thread.archive", &(&1["archivedAt"] != nil))
    else
      assert World.thread(context, thread)["archivedAt"] != nil
      context
    end
  end

  step "thread {string} was settled or unsettled by the user", %{args: [thread]} = context do
    update(context, thread, "thread.unsettle", &(&1["settledOverride"] == "active"))
  end

  step "thread {string} is pinned", %{args: [thread]} = context do
    update(context, thread, "thread.pin", &(&1["pinnedAt"] != nil))
  end

  step "thread {string} waits on an approval or a question", %{args: [thread]} = context do
    id = "rr-#{System.unique_integer([:positive])}"
    at = World.iso_from_now(0)

    context =
      World.put_entity(context, thread, "runtime-request", id, %{
        "s" => %{
          "id" => id,
          "threadId" => World.thread_id(context, thread),
          "kind" => "approval",
          "status" => "pending",
          "createdAt" => at,
          "updatedAt" => at
        }
      })

    World.await_row(World.thread_id(context, thread), &(&1["pendingRuntimeRequest"] != nil))
    context
  end

  step "thread {string} has a running turn", %{args: [thread]} = context do
    context = World.add_run(context, thread, "running")
    World.await_row(World.thread_id(context, thread), &(&1["activityRunStatus"] == "running"))
    context
  end

  step "thread {string} has background tasks still running", %{args: [thread]} = context do
    [run | _] = World.state(context, thread) |> HalC2.StreamState.list("run")
    id = "item-#{System.unique_integer([:positive])}"

    context =
      World.put_entity(context, thread, "turn-item", id, %{
        "s" => %{
          "id" => id,
          "threadId" => World.thread_id(context, thread),
          "runId" => run["id"],
          "type" => "command_execution",
          "status" => "running",
          "input" => "npm run dev"
        }
      })

    World.await_row(World.thread_id(context, thread), &(&1["pendingBackgroundTasks"] != []))
    context
  end

  step "thread {string} received a message less than two minutes ago",
       %{args: [thread]} = context do
    World.add_message(context, thread, "user", "Also this", World.iso_from_now(-30_000))
  end

  step "thread {string} is snoozed and has not woken since", %{args: [thread]} = context do
    World.patch_thread(context, thread, %{
      "snoozedAt" => World.iso_from_now(-@hour),
      "snoozedUntil" => World.iso_from_now(World.days(1))
    })
  end

  step "thread {string} was snoozed and a turn completed after the snooze",
       %{args: [thread]} = context do
    context
    |> ensure_thread(thread)
    |> World.patch_thread(thread, %{
      "createdAt" => World.iso_from_now(-2 * @hour),
      "snoozedAt" => World.iso_from_now(-@hour),
      "snoozedUntil" => World.iso_from_now(World.days(1))
    })
    |> World.add_run(thread, "completed", World.iso_from_now(-div(@hour, 2)))
  end

  step "its linked pull request merged after that", context do
    context |> link("t1") |> sync("t1", "merged", 0)
  end

  step "the node sweeps for threads to settle", context do
    Node.ensure({Settlement, interval: nil})
    :ok = Settlement.sweep()
    Map.put(context, :settle_swept, true)
  end

  step "its settled time is its last user activity", context do
    row = World.row(context, "t1")
    assert row["settledAt"] != nil

    assert HalC2.Projection.JS.epoch_ms(row["settledAt"]) ==
             HalC2.Projection.JS.epoch_ms(row["latestUserMessageAt"])

    context
  end

  step "thread {string} is not settled", %{args: [thread]} = context do
    assert World.thread(context, thread)["settledOverride"] != "settled"
    assert World.row(context, thread)["settledOverride"] != "settled"
    context
  end

  step "thread {string} is settled without waiting for the next periodic sweep",
       %{args: [thread]} = context do
    World.await_row(World.thread_id(context, thread), &(&1["settledOverride"] == "settled"))
    context
  end

  # The timer is the only thing that changes here: the service sweeps on its own
  # schedule, and "a minute passes" is the tick that schedule delivers. Backdating
  # the message changes no field the service watches, so no sweep starts by itself.
  step "thread {string} becomes eligible to settle", %{args: [thread]} = context do
    pid = Node.ensure({Settlement, interval: 60_000})
    context = ensure_thread(context, thread)
    :ok = Settlement.sweep()
    at = World.iso_from_now(-World.days(4))

    context =
      context
      |> World.patch_thread(thread, %{"createdAt" => at})
      |> World.add_message(thread, "user", "Ship it", at)

    _ = :sys.get_state(pid)
    assert World.thread(context, thread)["settledOverride"] == nil
    Map.put(context, :settlement, pid)
  end

  step "a minute passes", context do
    id = World.thread_id(context, "t1")
    send(context.settlement, :tick)
    World.await_row(id, &(&1["settledOverride"] == "settled"))
    Map.put(context, :settle_swept, true)
  end

  step "the node decided to settle {string} from a snapshot", %{args: [thread]} = context do
    context = finished(context, thread, -World.days(4))
    Map.put(context, :auto_settle, auto_settle(context, thread))
  end

  step "thread {string} was updated after that snapshot", %{args: [thread]} = context do
    snapshot = HalC2.Projection.JS.epoch_ms(context.auto_settle["snapshotAt"])
    context = World.patch_thread(context, thread, %{"title" => "Renamed"})
    assert HalC2.Projection.JS.epoch_ms(World.row(context, thread)["updatedAt"]) > snapshot
    context
  end

  step "the auto-settle command runs", context do
    Map.put(context, :auto_settle_result, HalC2.Orchestration.dispatch(context.auto_settle))
  end

  step "the user unsettled {string}", %{args: [thread]} = context do
    context
    |> ensure_thread(thread)
    |> update(thread, "thread.unsettle", &(&1["settledOverride"] == "active"))
  end

  step "an auto-settle command for {string} runs", %{args: [thread]} = context do
    result = HalC2.Orchestration.dispatch(auto_settle(context, thread))
    Map.put(context, :auto_settle_result, result)
  end

  step "the command is refused", context do
    assert {:error, message} = context.auto_settle_result
    assert message =~ "changed before automatic settlement"
    context
  end

  step "thread {string} stays active by override", %{args: [thread]} = context do
    assert World.thread(context, thread)["settledOverride"] == "active"
    context
  end

  step "thread {string} was auto-settled", %{args: [thread]} = context do
    context = finished(context, thread, -World.days(4))
    Node.ensure({Settlement, interval: nil})
    :ok = Settlement.sweep()
    World.await_row(World.thread_id(context, thread), &(&1["settledOverride"] == "settled"))
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  defp ensure_thread(context, thread) do
    if context.threads[thread], do: context, else: World.create_thread(context, thread, "demo")
  end

  # Backdates the thread and gives it a user message and a finished run `ago_ms` ago.
  defp finished(context, thread, ago_ms) do
    at = World.iso_from_now(ago_ms)

    context
    |> ensure_thread(thread)
    |> World.patch_thread(thread, %{"createdAt" => at})
    |> World.add_message(thread, "user", "Ship it", at)
    |> World.add_run(thread, "completed", at)
  end

  defp worked(context, thread, ago_ms) do
    context
    |> ensure_thread(thread)
    |> World.patch_thread(thread, %{"createdAt" => World.iso_from_now(ago_ms - @hour)})
    |> World.add_message(thread, "user", "Ship it", World.iso_from_now(ago_ms))
  end

  defp update(context, thread, type, done) do
    {{:ok, _}, context} =
      World.dispatch(context, %{"type" => type, "threadId" => World.thread_id(context, thread)})

    World.await_row(World.thread_id(context, thread), done)
    context
  end

  defp auto_settle(context, thread) do
    row = World.row(context, thread)

    %{
      "type" => "thread.auto-settle",
      "commandId" => "server:auto-settle:#{row["id"]}:#{HalC2.Environment.uuid4()}",
      "threadId" => row["id"],
      "snapshotAt" => row["updatedAt"],
      "settledAt" => row["latestUserMessageAt"] || row["createdAt"]
    }
  end

  defp write_settings(context, patch) do
    {settings, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(deep_merge(settings, patch), version)
    context
  end

  defp deep_merge(a, b),
    do:
      Map.merge(a, b, fn _, x, y -> if is_map(x) and is_map(y), do: deep_merge(x, y), else: y end)

  defp link(context, thread) do
    id = World.thread_id(context, thread)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.pull-request.link",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/demo",
        "number" => 5,
        "url" => "https://github.com/acme/demo/pull/5",
        "source" => "manual"
      })

    World.await_row(id, &(&1["pullRequests"] not in [nil, []]))
    context
  end

  defp sync(context, thread, state, ago_ms) do
    id = World.thread_id(context, thread)
    at = World.iso_from_now(ago_ms)

    snapshot =
      %{"state" => state, "title" => "PR 5", "syncedAt" => World.iso_from_now(0)}
      |> Map.merge(
        case state do
          "merged" -> %{"mergedAt" => at}
          "closed" -> %{"closedAt" => at}
          "open" -> %{}
        end
      )

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.pull-request-link.sync",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/demo",
        "number" => 5,
        "snapshot" => snapshot,
        "stack" => nil
      })

    World.await_row(id, fn row ->
      Enum.any?(row["pullRequests"] || [], &(&1["snapshot"]["state"] == state))
    end)

    context
  end
end
