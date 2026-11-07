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

    test "turning it off and on is not activity", %{thread_id: thread_id} do
      before = stream(thread_id).updated_at
      {:ok, _} = auto_settle_set(thread_id, false)
      assert stream(thread_id).updated_at == before
      {:ok, _} = auto_settle_set(thread_id, true)
      assert stream(thread_id).updated_at == before
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

  # Upstream #24610: only Claude implements `await_background/3`
  # (`hal_c2_background_wait`). On the other adapters (Codex here; the ACP
  # adapter behind Grok, Cursor, OpenCode and Antigravity is the same) the
  # mark is refused as unsupported, so a running command or monitor can never
  # hold the thread: settlement must not answer "has background work" for it,
  # and the thread may auto-settle while it runs. The work still counts as
  # running (`runningBackgroundTasks`), which is what the idle-session pin
  # and recovery read, so its process and files stay alive. A subagent holds
  # on every provider.
  test "a non-Claude provider's running background command does not block settlement", %{
    thread_id: thread_id
  } do
    {:ok, _} = Orchestration.dispatch(%{"type" => "thread.unsnooze", "threadId" => thread_id})

    item = fn id, type ->
      {"turn-item", id,
       %{
         "s" => %{
           "id" => id,
           "threadId" => thread_id,
           "runId" => "run-1",
           "type" => type,
           "status" => "running"
         }
       }}
    end

    {:ok, _} =
      HalC2.Streams.commit(thread_id, :thread, [
        {"run", "run-1", %{"s" => %{"id" => "run-1", "ordinal" => 1, "status" => "completed"}}},
        item.("cmd-1", "command_execution"),
        item.("mon-1", "dynamic_tool")
      ])

    row = HalC2.Projection.Shell.thread_shell(stream(thread_id))

    assert Enum.map(row["runningBackgroundTasks"], & &1["taskId"]) |> Enum.sort() ==
             ["cmd-1", "mon-1"]

    assert row["pendingBackgroundTasks"] == []
    assert HalC2.Orchestration.Settlement.blocker(row, System.system_time(:millisecond)) == nil
    assert {:ok, _} = auto_settle(thread_id)
    assert thread(thread_id)["settledOverride"] == "settled"

    # The running work is still listed after the settle, for idle release and recovery.
    row = HalC2.Projection.Shell.thread_shell(stream(thread_id))
    assert length(row["runningBackgroundTasks"]) == 2
  end

  test "a non-Claude provider's running subagent still blocks settlement", %{
    thread_id: thread_id
  } do
    {:ok, _} = Orchestration.dispatch(%{"type" => "thread.unsnooze", "threadId" => thread_id})

    {:ok, _} =
      HalC2.Streams.commit(thread_id, :thread, [
        {"run", "run-1", %{"s" => %{"id" => "run-1", "ordinal" => 1, "status" => "completed"}}},
        {"turn-item", "sub-1",
         %{
           "s" => %{
             "id" => "sub-1",
             "threadId" => thread_id,
             "runId" => "run-1",
             "type" => "subagent",
             "status" => "running"
           }
         }}
      ])

    row = HalC2.Projection.Shell.thread_shell(stream(thread_id))
    assert [%{"taskId" => "sub-1"}] = row["pendingBackgroundTasks"]

    assert HalC2.Orchestration.Settlement.blocker(row, System.system_time(:millisecond)) ==
             "has background work"
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
