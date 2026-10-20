defmodule HalC2.CodexSteerTest do
  use ExUnit.Case, async: false

  alias HalC2.Codex.ThreadRuntime

  setup do
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})

    on_exit(fn ->
      Application.delete_env(:hal_c2, :codex_steer_timeout_ms)
      Application.delete_env(:hal_c2, :codex_steer_settle_timeout_ms)
    end)

    :ok
  end

  # A definite refusal is not a delivery, however long the runtime then takes to
  # settle: only the steer call's own timeout may be answered `:ok`.
  test "a refused steer whose settle is held still answers the refusal" do
    Application.put_env(:hal_c2, :codex_steer_settle_timeout_ms, 50)
    stand_in("thread-1", {:error, "turn moved on"})

    assert {:error, "turn moved on"} =
             ThreadRuntime.steer("thread-1", "run-1", %{text: "hi", attachments: []})
  end

  test "a steer the runtime does not answer in time is taken as held by it" do
    Application.put_env(:hal_c2, :codex_steer_timeout_ms, 50)
    stand_in("thread-1", :hold)

    assert :ok = ThreadRuntime.steer("thread-1", "run-1", %{text: "hi", attachments: []})
  end

  # A timeout from the provider call nested inside the runtime kills the
  # runtime with that inner call's exit; it must not be answered `:ok`.
  test "a steer whose runtime dies on its nested provider call is not held" do
    stand_in("thread-1", :inner_timeout)

    assert catch_exit(ThreadRuntime.steer("thread-1", "run-1", %{text: "hi", attachments: []}))
  end

  # A process standing in for the runtime in its registry: it answers the steer
  # with `steer_reply` (`:hold` never answers it) and never answers `:settle`, as
  # a runtime busy with the notifications ahead of that call would not.
  defp stand_in(thread_id, steer_reply) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(HalC2.Codex.Registry, thread_id, nil)
        send(parent, :registered)
        loop(steer_reply)
      end)

    assert_receive :registered
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp loop(steer_reply) do
    receive do
      {:"$gen_call", from, {:steer, _run_id, _message}} ->
        case steer_reply do
          :hold -> :ok
          :inner_timeout -> exit({:timeout, {GenServer, :call, [:provider_conn, :call, 30_000]}})
          reply -> GenServer.reply(from, reply)
        end

        loop(steer_reply)

      {:"$gen_call", _from, :settle} ->
        loop(steer_reply)
    end
  end
end
