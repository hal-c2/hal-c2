defmodule HalC2.OrchestrationSettleTest do
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)

    thread_id = "thread-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Settle me",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    wake = "#{Date.add(Date.utc_today(), 1)}T09:00:00.000Z"

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.snooze",
        "threadId" => thread_id,
        "snoozedUntil" => wake
      })

    %{thread_id: thread_id}
  end

  defp stream(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))
  defp thread(thread_id), do: StreamState.get(stream(thread_id), "thread")[thread_id]

  # Settling emits thread.unsnoozed after thread.settled, and the
  # desktop's undo snoozes again because the MC ended the snooze.
  test "settling a snoozed thread ends its snooze", %{thread_id: thread_id} do
    {:ok, _} = Orchestration.dispatch(%{"type" => "thread.settle", "threadId" => thread_id})

    assert %{"settledOverride" => "settled", "snoozedUntil" => nil, "snoozedAt" => nil} =
             thread(thread_id)
  end

  test "an automatic settle of a snoozed thread ends its snooze", %{thread_id: thread_id} do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.auto-settle",
        "threadId" => thread_id,
        "snapshotAt" => HalC2.Projection.JS.iso(stream(thread_id).updated_at),
        "settledAt" => "2026-01-01T00:00:00.000Z"
      })

    assert %{
             "settledOverride" => "settled",
             "settledAt" => "2026-01-01T00:00:00.000Z",
             "snoozedUntil" => nil,
             "snoozedAt" => nil
           } = thread(thread_id)
  end

  defp auto_settle(thread_id),
    do:
      Orchestration.dispatch(%{
        "type" => "thread.auto-settle",
        "threadId" => thread_id,
        "snapshotAt" => HalC2.Projection.JS.iso(stream(thread_id).updated_at),
        "settledAt" => "2026-01-01T00:00:00.000Z"
      })

  defp auto_settle_set(thread_id, enabled),
    do:
      Orchestration.dispatch(%{
        "type" => "thread.auto-settle.set",
        "threadId" => thread_id,
        "enabled" => enabled
      })

  describe "per-thread auto-settle (thread.auto-settle.set)" do
    test "turning it off keeps automatic settlement away until it is turned on", %{
      thread_id: thread_id
    } do
      {:ok, _} = auto_settle_set(thread_id, false)
      assert %{"autoSettleDisabledAt" => off} = thread(thread_id)
      assert off != nil
      assert {:error, _} = auto_settle(thread_id)
      assert thread(thread_id)["settledOverride"] == nil

      # Turning it off again keeps when it was first turned off.
      {:ok, _} = auto_settle_set(thread_id, false)
      assert thread(thread_id)["autoSettleDisabledAt"] == off

      {:ok, _} = auto_settle_set(thread_id, true)
      assert thread(thread_id)["autoSettleDisabledAt"] == nil
      assert {:ok, _} = auto_settle(thread_id)
      assert thread(thread_id)["settledOverride"] == "settled"
    end

    test "settling and un-settling by hand still work and keep it off", %{thread_id: thread_id} do
      {:ok, _} = auto_settle_set(thread_id, false)
      {:ok, _} = Orchestration.dispatch(%{"type" => "thread.settle", "threadId" => thread_id})
      assert %{"settledOverride" => "settled", "autoSettleDisabledAt" => off} = thread(thread_id)
      assert off != nil

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.unsettle",
          "threadId" => thread_id,
          "reason" => "user"
        })

      assert %{"settledOverride" => "active", "autoSettleDisabledAt" => ^off} = thread(thread_id)
    end

    test "turning it off and on is not activity", %{thread_id: thread_id} do
      # The thread's last activity was a week ago.
      week_ago = System.system_time(:millisecond) - 7 * 24 * 60 * 60 * 1000

      {:ok, _} =
        HalC2.Streams.commit(thread_id, :thread, [
          {"thread", thread_id, %{"s" => %{"title" => "Settle me"}}, week_ago}
        ])

      updated_at = stream(thread_id).updated_at
      assert updated_at == week_ago
      row = HalC2.Projection.Shell.thread_shell(stream(thread_id))

      {:ok, _} = auto_settle_set(thread_id, false)
      {:ok, _} = auto_settle_set(thread_id, true)

      assert stream(thread_id).updated_at == updated_at

      assert HalC2.Projection.Shell.thread_shell(stream(thread_id))["updatedAt"] ==
               row["updatedAt"]
    end

    test "the sidebar row carries it, and settlement names it as the blocker", %{
      thread_id: thread_id
    } do
      {:ok, _} = auto_settle_set(thread_id, false)
      row = HalC2.Projection.Shell.thread_shell(stream(thread_id))
      assert row["autoSettleDisabledAt"] != nil

      assert HalC2.Orchestration.Settlement.blocker(row, System.system_time(:millisecond)) =~
               "auto-settle"
    end

    test "an archived thread refuses it", %{thread_id: thread_id} do
      {:ok, _} = Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => thread_id})
      assert {:error, _} = auto_settle_set(thread_id, false)
    end

    test "it needs enabled", %{thread_id: thread_id} do
      assert {:error, _} =
               Orchestration.dispatch(%{
                 "type" => "thread.auto-settle.set",
                 "threadId" => thread_id
               })
    end
  end

  # A question the agent asked in the background is answered with a message, so it does
  # not block settling; settling dismisses it unanswered.
  test "settling dismisses questions the agent asked in the background", %{thread_id: thread_id} do
    {:ok, _} =
      HalC2.Streams.commit(thread_id, :thread, [
        {"runtime-request", "runtime-request:codex:bg",
         %{
           "s" => %{
             "id" => "runtime-request:codex:bg",
             "status" => "pending",
             "nodeId" => "node:approval:bg",
             "responseCapability" => %{"type" => "message"}
           }
         }},
        {"turn-item", "turn-item:approval:bg",
         %{"s" => %{"id" => "turn-item:approval:bg", "status" => "running", "ordinal" => 0}}}
      ])

    {:ok, _} = Orchestration.dispatch(%{"type" => "thread.settle", "threadId" => thread_id})

    state = stream(thread_id)

    assert %{"status" => "cancelled"} =
             StreamState.get(state, "runtime-request")["runtime-request:codex:bg"]

    assert %{"status" => "cancelled"} =
             StreamState.get(state, "turn-item")["turn-item:approval:bg"]

    assert thread(thread_id)["settledOverride"] == "settled"
  end
end
