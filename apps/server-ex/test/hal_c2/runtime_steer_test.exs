defmodule HalC2.RuntimeSteerTest do
  use ExUnit.Case, async: true

  alias HalC2.RuntimeSteer

  # The contract every bundled runtime's steer shares: only the steer call's
  # own timeout is answered `:ok` (the runtime still holds the request).

  test "its own timeout is answered :ok" do
    pid = stand_in(:hold)

    assert :ok = RuntimeSteer.call(pid, "run-1", %{text: "hi", attachments: []}, 50)
  end

  test "a refusal is answered as the refusal" do
    pid = stand_in({:error, "no running turn"})

    assert {:error, "no running turn"} =
             RuntimeSteer.call(pid, "run-1", %{text: "hi", attachments: []}, 5_000)
  end

  test "a runtime that stops is not taken as held" do
    parent = self()
    pid = stand_in(:hold, parent)

    task =
      Task.async(fn ->
        catch_exit(RuntimeSteer.call(pid, "run-1", %{text: "hi", attachments: []}, 5_000))
      end)

    assert_receive :steer_received
    Process.exit(pid, :kill)

    assert Task.await(task)
  end

  # A timeout from a provider call nested inside the runtime takes the
  # runtime down with that inner call's exit; it is not this call's timeout.
  test "a runtime dying on its nested provider call is not taken as held" do
    pid = stand_in(:inner_timeout)

    assert catch_exit(RuntimeSteer.call(pid, "run-1", %{text: "hi", attachments: []}, 5_000))
  end

  defp stand_in(steer_reply, notify \\ nil) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, :ready)
        loop(notify || parent, steer_reply)
      end)

    assert_receive :ready
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp loop(parent, steer_reply) do
    receive do
      {:"$gen_call", from, {:steer, _run_id, _message}} ->
        send(parent, :steer_received)

        case steer_reply do
          :hold -> :ok
          :inner_timeout -> exit({:timeout, {GenServer, :call, [:provider_conn, :call, 30_000]}})
          reply -> GenServer.reply(from, reply)
        end

        loop(parent, steer_reply)
    end
  end
end
