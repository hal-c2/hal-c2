defmodule HalC2.Steps.Orchestration.ThreadOrganization do
  @moduledoc "Steps for `features/mc/orchestration/thread-organization.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

  defp organize(context, thread, type, fields \\ %{}) do
    context
    |> Map.put(:thread, thread)
    |> World.command(Map.merge(%{"type" => type, "threadId" => thread}, fields))
  end

  defp ok!(context) do
    assert {:ok, _} = context.reply, "command failed: #{inspect(context.reply)}"
    Map.delete(context, :reply)
  end

  defp at_nine(date), do: "#{date}T09:00:00.000Z"

  # "tomorrow 09:00", "next Monday 09:00" (UTC), or "a past time".
  defp wake_time("tomorrow 09:00"), do: at_nine(Date.add(Date.utc_today(), 1))

  defp wake_time("next Monday 09:00") do
    today = Date.utc_today()
    at_nine(Date.add(today, 8 - Date.day_of_week(today)))
  end

  defp wake_time("a past time"), do: World.iso_from_now(-60 * 60 * 1_000)

  defp last_thread_patch(context, thread) do
    context
    |> World.events(thread)
    |> Enum.filter(&(&1.kind == "thread" and &1.entity == World.thread_id(context, thread)))
    |> List.last()
    |> Map.fetch!(:patch)
  end

  step "a client settles {string}", %{args: [thread]} = context do
    organize(context, thread, "thread.settle")
  end

  step "thread {string} is settled by override", %{args: [thread]} = context do
    assert {:ok, _} = context.reply
    assert World.thread(context, thread)["settledOverride"] == "settled"
    context
  end

  step "thread {string} records when it was settled", %{args: [thread]} = context do
    assert is_binary(World.thread(context, thread)["settledAt"])
    context
  end

  step "thread {string} is active by override", %{args: [thread]} = context do
    assert {:ok, _} = context.reply
    assert World.thread(context, thread)["settledOverride"] == "active"
    context
  end

  step "thread {string} has no settled time", %{args: [thread]} = context do
    assert World.thread(context, thread)["settledAt"] == nil
    context
  end

  step "thread {string} records when it was unsettled", %{args: [thread]} = context do
    assert is_binary(World.thread(context, thread)["unsettledAt"])
    context
  end

  # What each organization event sets on the thread.
  @recorded %{
    "settled" => %{"settledOverride" => "settled"},
    "unsettled" => %{"settledOverride" => "active", "settledAt" => nil},
    "snoozed" => %{},
    "unsnoozed" => %{"snoozedUntil" => nil, "snoozedAt" => nil},
    "pinned" => %{},
    "unpinned" => %{"pinnedAt" => nil, "pinOrderKey" => nil},
    "active-reordered" => %{}
  }
  @stamped %{
    "settled" => ["settledAt"],
    "unsettled" => ["unsettledAt"],
    "snoozed" => ["snoozedUntil", "snoozedAt"],
    "pinned" => ["pinnedAt", "pinOrderKey"],
    "active-reordered" => ["activeOrderKey"]
  }

  step ~r/^a thread-(?<event>settled|unsettled|snoozed|unsnoozed|pinned|unpinned|active-reordered) event is recorded$/,
       %{args: [event]} = context do
    assert {:ok, _} = context.reply
    patch = last_thread_patch(context, context.thread)
    set = patch["s"] || %{}
    assert Map.take(set, Map.keys(@recorded[event])) == @recorded[event]

    for key <- @stamped[event] || [],
        do: assert(is_binary(set[key] || patch["a"][key]), "#{key} not set")

    context
  end

  step ~r/^thread "(?<thread>[^"]+)" is snoozed until (?<until>tomorrow 09:00|next Monday 09:00)$/,
       %{args: [thread, until]} = context do
    if World.given?(context) do
      organize(context, thread, "thread.snooze", %{"snoozedUntil" => wake_time(until)}) |> ok!()
    else
      assert {:ok, _} = context.reply
      assert World.thread(context, thread)["snoozedUntil"] == wake_time(until)
      context
    end
  end

  step "thread {string} records when it was snoozed", %{args: [thread]} = context do
    assert is_binary(World.thread(context, thread)["snoozedAt"])
    context
  end

  step "thread {string} has no snooze time and no snoozed-at time", %{args: [thread]} = context do
    assert {:ok, _} = context.reply
    assert %{"snoozedUntil" => nil, "snoozedAt" => nil} = World.thread(context, thread)
    context
  end

  step "a client pins {string} with order key {string}", %{args: [thread, key]} = context do
    organize(context, thread, "thread.pin", %{"orderKey" => key})
  end

  step "thread {string} is pinned with order key {string}", %{args: [thread, key]} = context do
    if World.given?(context) do
      context = organize(context, thread, "thread.pin", %{"orderKey" => key}) |> ok!()
      Map.put(context, :pinned_at, World.thread(context, thread)["pinnedAt"])
    else
      assert {:ok, _} = context.reply
      assert %{"pinOrderKey" => ^key, "pinnedAt" => pinned} = World.thread(context, thread)
      assert is_binary(pinned)
      context
    end
  end

  step "a client unpins {string}", %{args: [thread]} = context do
    organize(context, thread, "thread.unpin")
  end

  step "thread {string} is not pinned and has no pinned order key", %{args: [thread]} = context do
    assert {:ok, _} = context.reply
    assert %{"pinnedAt" => nil, "pinOrderKey" => nil} = World.thread(context, thread)
    context
  end

  step "a client moves pinned thread {string} to order key {string}",
       %{args: [thread, key]} = context do
    organize(context, thread, "thread.pin.reorder", %{"orderKey" => key})
  end

  step "the time it was pinned is unchanged", context do
    assert World.thread(context, context.thread)["pinnedAt"] == context.pinned_at
    context
  end

  step "a client moves active thread {string} to order key {string}",
       %{args: [thread, key]} = context do
    organize(context, thread, "thread.active.reorder", %{"orderKey" => key})
  end

  step "thread {string} has active order key {string}", %{args: [thread, key]} = context do
    assert {:ok, _} = context.reply
    assert World.thread(context, thread)["activeOrderKey"] == key
    context
  end

  step "thread {string} is neither settled nor snoozed", %{args: [thread]} = context do
    organized = World.thread(context, thread)
    refute organized["settledOverride"] == "settled"
    assert [nil, nil, nil] == Enum.map(~w(settledAt snoozedUntil snoozedAt), &organized[&1])
    context
  end

  step "the user sends a message to {string}", %{args: [thread]} = context do
    context |> World.providers() |> World.dispatch_message(thread, "carry on") |> ok!()
  end

  step "thread {string} has a delegated task result queued", %{args: [thread]} = context do
    message = "msg-delegated-result"

    context
    |> World.add_message(thread, "user", "<delegated_task_result/>", nil, %{
      "id" => message,
      "createdBy" => "system",
      "delegatedCompletion" => %{"taskIds" => ["task-1"], "acceptedAt" => nil}
    })
    |> World.add_run(thread, "queued", nil, %{"userMessageId" => message, "queuePosition" => 1})
    |> Map.put(:delegated_result, message)
  end

  step "the queued delegated task result is cancelled", context do
    assert [%{"status" => "cancelled", "queuePosition" => nil}] =
             context
             |> World.entities(context.thread, "run")
             |> Enum.filter(&(&1["userMessageId"] == context.delegated_result))

    context
  end

  # --- states a thread cannot rest in -----------------------------------------------

  step "thread {string} waits for an approval", %{args: [thread]} = context do
    waiting(context, thread, "approve the command")
  end

  step "thread {string} waits for an answer to a question", %{args: [thread]} = context do
    waiting(context, thread, "ask me something")
  end

  step "thread {string} has a queued run that has not started", %{args: [thread]} = context do
    context |> World.running_turn(thread) |> World.queue_message(thread, "after that")
  end

  step "thread {string} is idle", %{args: [thread]} = context do
    assert World.entities(context, thread, "run") == []
    context
  end

  defp waiting(context, thread, text) do
    context = context |> World.providers() |> World.dispatch_message(thread, text) |> ok!()

    World.await_state(context, thread, fn state ->
      Enum.any?(HalC2.StreamState.list(state, "runtime-request"), &(&1["status"] == "pending"))
    end)

    context
  end

  step "the command fails and {string} is not snoozed", %{args: [thread]} = context do
    assert {:error, _, _} = context.reply
    assert World.thread(context, thread)["snoozedUntil"] == context.snooze_before["snoozedUntil"]
    context
  end

  step "the command fails because the agent is still working", context do
    assert {:error, error, _} = context.reply
    assert error =~ "running"
    context
  end

  step "a client sends {string} for thread {string}", %{args: [type, thread]} = context do
    World.command(context, %{
      "type" => type,
      "threadId" => thread,
      "orderKey" => "a0",
      "snoozedUntil" => wake_time("tomorrow 09:00")
    })
  end

  step "thread {string} is pinned and snoozed", %{args: [thread]} = context do
    context
    |> organize(thread, "thread.pin", %{"orderKey" => "a0"})
    |> ok!()
    |> organize(thread, "thread.snooze", %{"snoozedUntil" => wake_time("tomorrow 09:00")})
    |> ok!()
    |> then(&Map.put(&1, {:organized, thread}, World.thread(&1, thread)))
  end

  step "thread {string} is snoozed and settled", %{args: [thread]} = context do
    context
    |> organize(thread, "thread.snooze", %{"snoozedUntil" => wake_time("tomorrow 09:00")})
    |> ok!()
    |> organize(thread, "thread.settle")
    |> ok!()
    |> then(&Map.put(&1, {:organized, thread}, World.thread(&1, thread)))
  end

  step "thread {string} is still pinned and snoozed", %{args: [thread]} = context do
    organized = still_organized(context, thread)
    assert %{"pinOrderKey" => "a0"} = organized
    assert organized["pinnedAt"] != nil
    assert organized["snoozedUntil"] == wake_time("tomorrow 09:00")
    context
  end

  step "thread {string} is still snoozed and settled", %{args: [thread]} = context do
    organized = still_organized(context, thread)
    assert %{"settledOverride" => "settled"} = organized
    assert organized["snoozedUntil"] == wake_time("tomorrow 09:00")
    context
  end

  defp still_organized(context, thread) do
    organized =
      Map.take(
        World.thread(context, thread),
        ~w(pinnedAt pinOrderKey snoozedUntil snoozedAt settledOverride settledAt)
      )

    assert organized == Map.take(context[{:organized, thread}], Map.keys(organized))
    organized
  end
end
