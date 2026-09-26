defmodule T3.Steps.Threads do
  @moduledoc "Steps for `features/threads/`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Orchestration.Settlement
  alias T3.Test.Node
  alias T3.Test.Node.World

  # --- settle.feature ------------------------------------------------------------------

  step "the auto-settle rule is {string}", %{args: [rule]} = context do
    [days] = Regex.run(~r/after (\d+) days? of inactivity/, rule, capture: :all_but_first)

    context
    |> settings()
    |> write_settings(%{"sidebarAutoSettleAfterDays" => String.to_integer(days)})
  end

  step "the environment settles threads after {int} days", %{args: [days]} = context do
    context |> settings() |> write_settings(%{"sidebarAutoSettleAfterDays" => days})
  end

  step "the project {string} settles threads after {int} day(s)",
       %{args: [title, days]} = context do
    id = World.project(context, title).id

    context
    |> settings()
    |> write_settings(%{
      "projectSettingsOverrides" => %{id => %{"sidebarAutoSettleAfterDays" => days}}
    })
  end

  step "{string} has had no activity for {int} day(s)", %{args: [thread, days]} = context do
    at = World.iso_from_now(-World.days(days) - 60_000)
    context = World.patch_thread(context, thread, %{"createdAt" => at})
    World.add_message(context, thread, "user", "Ship it", at)
  end

  step "{string} is linked to a pull request", %{args: [thread]} = context do
    link(context, thread, 5)
  end

  step "{string} is linked to an open pull request", %{args: [thread]} = context do
    context = link(context, thread, 5)
    sync(context, thread, 5, %{"state" => "open"})
  end

  step "the pull request is merged", context do
    sync(context, "Ship checkout", 5, %{"state" => "merged", "mergedAt" => World.iso_from_now(0)})
  end

  step "the user has not written since the pull request was closed", context do
    sync(context, "Ship checkout", 5, %{"state" => "closed", "closedAt" => World.iso_from_now(0)})
  end

  step "{string} was linked to a pull request that merged last week",
       %{args: [thread]} = context do
    context = link(context, thread, 5)

    sync(context, thread, 5, %{
      "state" => "merged",
      "mergedAt" => World.iso_from_now(-World.days(7))
    })
  end

  step "{string} settled automatically", %{args: [thread]} = context do
    context =
      context
      |> settings()
      |> World.add_message(thread, "user", "Ship it", World.iso_from_now(-World.days(4)))

    :ok = Settlement.sweep()
    assert World.row(context, thread)["settledOverride"] == "settled"
    context
  end

  step "the settle sweep decided to settle {string}", %{args: [thread]} = context do
    context =
      World.add_message(context, thread, "user", "Ship it", World.iso_from_now(-World.days(4)))

    row = World.row(context, thread)

    Map.put(context, :pending_settle, %{
      "type" => "thread.auto-settle",
      "commandId" => "server:auto-settle:#{row["id"]}:#{T3.Environment.uuid4()}",
      "threadId" => row["id"],
      "snapshotAt" => row["updatedAt"],
      "settledAt" => row["latestUserMessageAt"]
    })
  end

  step "the user writes in {string} before the settle is applied", %{args: [thread]} = context do
    context = World.add_message(context, thread, "user", "One more thing")
    assert {:error, _} = T3.Orchestration.dispatch(context.pending_settle)
    context
  end

  step "{string} has an agent run in progress", %{args: [thread]} = context do
    World.add_run(context, thread, "running")
  end

  step "{string} is waiting for an approval or an answer", %{args: [thread]} = context do
    id = "rr-#{System.unique_integer([:positive])}"
    at = World.iso_from_now(0)

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
  end

  step "{string} is still snoozed", %{args: [thread]} = context do
    World.patch_thread(context, thread, %{
      "snoozedAt" => World.iso_from_now(-1000),
      "snoozedUntil" => World.iso_from_now(World.days(1))
    })
  end

  step "{string} received a message from the user just now", %{args: [thread]} = context do
    World.add_message(context, thread, "user", "Also this")
  end

  step "the user sends a new message in {string}", %{args: [thread]} = context do
    World.add_message(context, thread, "user", "Also this")
  end

  step "the user un-settles {string}", %{args: [thread]} = context do
    {{:ok, _}, context} =
      World.dispatch(context, %{
        "type" => "thread.unsettle",
        "threadId" => World.thread_id(context, thread)
      })

    World.await_row(World.thread_id(context, thread), &(&1["settledOverride"] == "active"))
    context
  end

  step "the settle sweep runs", context do
    context = settings(context)
    :ok = Settlement.sweep()
    context
  end

  step "{string} is settled automatically", %{args: [thread]} = context do
    context = settings(context)
    :ok = Settlement.sweep()
    id = World.thread_id(context, thread)
    World.await_row(id, &(&1["settledOverride"] == "settled"))
    context
  end

  step "{string} stays active", %{args: [thread]} = context do
    assert World.row(context, thread)["settledOverride"] in [nil, "active"]
    context
  end

  # The settlement service reads settings and sweeps only when asked.
  defp settings(context) do
    Node.ensure(T3.Settings)
    Node.ensure({Settlement, interval: nil})
    context
  end

  defp write_settings(context, patch) do
    {settings, version} = T3.Settings.get()
    {:ok, _} = T3.Settings.put(deep_merge(settings, patch), version)
    context
  end

  defp deep_merge(a, b),
    do:
      Map.merge(a, b, fn _, x, y -> if is_map(x) and is_map(y), do: deep_merge(x, y), else: y end)

  defp link(context, thread, number) do
    id = World.thread_id(context, thread)

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "thread.pull-request.link",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/shop",
        "number" => number,
        "url" => "https://github.com/acme/shop/pull/#{number}",
        "source" => "manual"
      })

    World.await_row(id, &(&1["pullRequests"] != nil and &1["pullRequests"] != []))
    context
  end

  defp sync(context, thread, number, snapshot) do
    id = World.thread_id(context, thread)

    snapshot =
      Map.merge(%{"title" => "PR #{number}", "syncedAt" => World.iso_from_now(0)}, snapshot)

    {:ok, _} =
      T3.Orchestration.dispatch(%{
        "type" => "thread.pull-request-link.sync",
        "threadId" => id,
        "host" => "github.com",
        "repository" => "acme/shop",
        "number" => number,
        "snapshot" => snapshot,
        "stack" => nil
      })

    World.await_row(id, fn row ->
      Enum.any?(row["pullRequests"] || [], &(&1["snapshot"]["state"] == snapshot["state"]))
    end)

    context
  end
end
