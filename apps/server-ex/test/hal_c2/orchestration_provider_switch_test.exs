defmodule HalC2.OrchestrationProviderSwitchTest do
  # A provider the project turned off refuses what would start or steer a turn on it;
  # `prop/hal_c2/orchestration_prop_test.exs` models the rest.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)

  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    on_exit(fn -> Application.delete_env(:hal_c2, :codex_command) end)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(HalC2.Settings)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})
    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})

    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Guards",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    %{thread_id: thread_id}
  end

  test "a queued message for a provider the project turned off is not promoted",
       %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    [running] = await_statuses(thread_id, ["running"])
    {:ok, _} = send_message(thread_id, "m2")
    [_, queued] = await_statuses(thread_id, ["running", "queued"])
    turn_off("codex")

    assert {:error, "Codex is turned off for this project." <> _} =
             Orchestration.dispatch(%{
               "type" => "queued-message.promote-to-steer",
               "threadId" => thread_id,
               "queuedRunId" => queued["id"],
               "targetRunId" => running["id"]
             })

    assert ["running", "queued"] = Enum.map(runs(current(thread_id)), & &1["status"])
  end

  test "a thread is not switched to a provider the project turned off",
       %{thread_id: thread_id} do
    {:ok, _} =
      HalC2.Settings.update(
        &Map.put(&1, "providerInstances", %{"codex-work" => %{"driver" => "codex"}})
      )

    turn_off("codex-work")

    for type <- ~w(provider.switch thread.model-selection.set) do
      assert {:error, "Codex" <> _ = reason} =
               Orchestration.dispatch(%{
                 "type" => type,
                 "threadId" => thread_id,
                 "modelSelection" => %{"instanceId" => "codex-work", "model" => "gpt-5.4"}
               })

      assert reason =~ "turned off for this project"
    end

    thread = StreamState.get(current(thread_id), "thread")[thread_id]
    assert thread["modelSelection"]["instanceId"] == "codex"
  end

  test "an answer by message to a provider the project turned off keeps the question open",
       %{thread_id: thread_id} do
    {:ok, _} = send_message(thread_id, "m1")
    await_statuses(thread_id, ["running"])
    request = ask_by_message(thread_id, "ask-1")
    turn_off("codex")

    assert {:error, "Codex is turned off for this project." <> _} =
             Orchestration.dispatch(%{
               "type" => "runtime-request.respond",
               "threadId" => thread_id,
               "requestId" => request["id"],
               "answers" => %{"0" => "Red"}
             })

    assert %{"status" => "pending"} =
             StreamState.get(current(thread_id), "runtime-request")[request["id"]]
  end

  # The running turn's agent asks a question it is answered by message.
  defp ask_by_message(thread_id, rid) do
    [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
    runtime = :sys.get_state(pid)

    send(
      pid,
      {:json_rpc, runtime.conn,
       {:notification, "item/completed",
        %{
          "threadId" => runtime.native_thread_id,
          "turnId" => runtime.turn.native_turn_id,
          "item" => %{
            "type" => "agentMessage",
            "id" => rid,
            "delivery" => "async",
            "text" => "",
            "questions" => [%{"title" => "wait #{rid}", "options" => ["Red"]}]
          }
        }}}
    )

    await_request(thread_id, "runtime-request:codex:async:" <> rid)
  end

  defp await_request(thread_id, id) do
    case StreamState.get(current(thread_id), "runtime-request")[id] do
      %{"status" => "pending"} = request ->
        request

      _ ->
        receive do
          {:hal_c2_stream, ^thread_id, _} -> await_request(thread_id, id)
        after
          5_000 -> flunk("#{id} was never asked")
        end
    end
  end

  defp send_message(thread_id, message_id, text \\ nil, mode \\ "queue_after_active") do
    Orchestration.dispatch(%{
      "type" => "message.dispatch",
      "threadId" => thread_id,
      "messageId" => message_id,
      "text" => text || "wait #{message_id}",
      "attachments" => [],
      "dispatchMode" => %{"type" => mode}
    })
  end

  defp turn_off(instance) do
    {:ok, _} =
      HalC2.Settings.update(
        &put_in(&1, ["projectSettingsOverrides"], %{
          "project-1" => %{"providerInstances" => %{instance => %{"enabled" => false}}}
        })
      )
  end

  defp current(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  # Waits until the thread's runs, in order, have these statuses; returns the runs.
  defp await_statuses(thread_id, statuses) do
    runs = runs(current(thread_id))

    if Enum.map(runs, & &1["status"]) == statuses do
      runs
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_statuses(thread_id, statuses)
      after
        5_000 -> flunk("runs never reached #{inspect(statuses)}")
      end
    end
  end
end
