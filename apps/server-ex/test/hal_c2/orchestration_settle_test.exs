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

  # The Node server's settle emits thread.unsnoozed after thread.settled, and the
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
end
