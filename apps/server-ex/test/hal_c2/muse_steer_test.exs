defmodule HalC2.MuseSteerTest do
  use ExUnit.Case, async: false

  alias HalC2.Muse.ThreadRuntime

  setup do
    start_supervised!({Registry, keys: :unique, name: HalC2.Muse.Registry})
    on_exit(fn -> Application.delete_env(:hal_c2, :muse_steer_timeout_ms) end)
    :ok
  end

  # As Codex's stand-in test pins for Codex: only the steer call's own timeout may
  # be answered `:ok` (the runtime still holds the request); a definite refusal
  # stays a refusal, and a runtime that stops is not a delivery either. Muse's
  # handler catches a nested provider-call timeout itself and answers such a
  # refusal (see `steer_call/3`), which this refusal case also covers.
  test "a steer the runtime does not answer in time is taken as held by it" do
    Application.put_env(:hal_c2, :muse_steer_timeout_ms, 50)
    stand_in("thread-1", :hold)

    assert :ok = ThreadRuntime.steer("thread-1", "run-1", %{text: "hi", attachments: []})
  end

  test "a refused steer still answers the refusal" do
    stand_in("thread-1", {:error, "Muse Code did not answer turn/steer"})

    assert {:error, "Muse Code did not answer turn/steer"} =
             ThreadRuntime.steer("thread-1", "run-1", %{text: "hi", attachments: []})
  end

  # Kill the stand-in while the steer call is in flight: killing it first
  # races the Registry dropping its entry, which answers "no active Muse turn"
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
        {:ok, _} = Registry.register(HalC2.Muse.Registry, thread_id, nil)
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
