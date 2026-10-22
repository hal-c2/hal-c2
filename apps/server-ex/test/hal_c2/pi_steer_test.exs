defmodule HalC2.PiSteerTest do
  use ExUnit.Case, async: false

  alias HalC2.Pi.ThreadRuntime

  setup do
    start_supervised!({Registry, keys: :unique, name: HalC2.Pi.Registry})
    :ok
  end

  # Pi's caller has no budget of its own (the runtime's answer timer decides when
  # Pi is taken to hold a steer, pinned in `pi_steer_prop_test.exs`): a definite
  # refusal stays a refusal, and a runtime that stops is not a delivery either.
  test "a refused steer still answers the refusal" do
    stand_in("thread-1", {:error, "no running turn"})

    assert {:error, "no running turn"} =
             ThreadRuntime.steer("thread-1", "run-1", %{text: "hi", attachments: []})
  end

  # Kill the stand-in while the steer call is in flight: killing it first
  # races the Registry dropping its entry, which answers "no active Pi turn"
  # instead of exiting.
  test "a steer whose runtime stops is not taken as held" do
    pid = stand_in("thread-1", :hold)

    task =
      Task.async(fn ->
        catch_exit(ThreadRuntime.steer("thread-1", "run-1", %{text: "hi", attachments: []}))
      end)

    assert_receive :steer_received
    Process.exit(pid, :kill)

    assert Task.await(task)
  end

  # A process standing in for the runtime in its registry: it answers the steer
  # with `steer_reply` (`:hold` never answers it), as a runtime busy with the
  # messages ahead of that call would not.
  defp stand_in(thread_id, steer_reply) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(HalC2.Pi.Registry, thread_id, nil)
        send(parent, :registered)
        loop(parent, steer_reply)
      end)

    assert_receive :registered
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp loop(parent, steer_reply) do
    receive do
      {:"$gen_call", from, {:steer, _run_id, _message}} ->
        send(parent, :steer_received)
        if steer_reply != :hold, do: GenServer.reply(from, steer_reply)
        loop(parent, steer_reply)
    end
  end
end
