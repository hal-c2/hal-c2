defmodule HalC2.ClaudeSteerTest do
  use ExUnit.Case, async: false

  alias HalC2.Claude.ThreadRuntime

  setup do
    start_supervised!({Registry, keys: :unique, name: HalC2.Claude.Registry})
    on_exit(fn -> Application.delete_env(:hal_c2, :claude_steer_timeout_ms) end)
    :ok
  end

  # As Codex's stand-in test pins for Codex: only the steer call's own timeout may
  # be answered `:ok` (the runtime still holds the request); a definite refusal
  # stays a refusal, and a runtime that stops is not a delivery either.
  test "a steer the runtime does not answer in time is taken as held by it" do
    Application.put_env(:hal_c2, :claude_steer_timeout_ms, 50)
    stand_in("thread-1", :hold)

    assert :ok = ThreadRuntime.steer("thread-1", "run-1", %{text: "hi", attachments: []})
  end

  test "a refused steer still answers the refusal" do
    stand_in("thread-1", {:error, "no running turn"})

    assert {:error, "no running turn"} =
             ThreadRuntime.steer("thread-1", "run-1", %{text: "hi", attachments: []})
  end

  test "a steer whose runtime stops is not taken as held" do
    pid = stand_in("thread-1", :hold)
    Process.exit(pid, :kill)

    assert catch_exit(ThreadRuntime.steer("thread-1", "run-1", %{text: "hi", attachments: []}))
  end

  # A process standing in for the runtime in its registry: it answers the steer
  # with `steer_reply` (`:hold` never answers it), as a runtime busy with the
  # messages ahead of that call would not.
  defp stand_in(thread_id, steer_reply) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(HalC2.Claude.Registry, thread_id, nil)
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
        if steer_reply != :hold, do: GenServer.reply(from, steer_reply)
        loop(steer_reply)
    end
  end
end
