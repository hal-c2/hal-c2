defmodule HalC2.RuntimeRespondTest do
  use ExUnit.Case, async: true

  alias HalC2.RuntimeRespond

  # The contract every bundled runtime's respond shares: only the respond call's
  # own timeout is answered `:ok` (the runtime still holds the answer).

  test "a runtime too busy to answer in time still holds the answer" do
    pid = stand_in(:hold)

    assert :ok = RuntimeRespond.call(pid, "request-1", %{"answers" => %{}}, 50)
  end

  test "a refusal is answered as the refusal" do
    pid = stand_in({:error, "no pending request request-1"})

    assert {:error, "no pending request request-1"} =
             RuntimeRespond.call(pid, "request-1", %{}, 5_000)
  end

  test "a runtime that stops is not taken as holding the answer" do
    pid = stand_in(:hold)

    task = Task.async(fn -> catch_exit(RuntimeRespond.call(pid, "request-1", %{}, 5_000)) end)

    assert_receive :respond_received
    Process.exit(pid, :kill)

    assert Task.await(task)
  end

  test "a runtime dying on a nested call is not taken as holding the answer" do
    pid = stand_in(:inner_timeout)

    assert catch_exit(RuntimeRespond.call(pid, "request-1", %{}, 5_000))
  end

  defp stand_in(reply) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, :ready)
        loop(parent, reply)
      end)

    assert_receive :ready
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp loop(parent, reply) do
    receive do
      {:"$gen_call", from, {:respond, _request_id, _response}} ->
        send(parent, :respond_received)

        case reply do
          :hold -> :ok
          :inner_timeout -> exit({:timeout, {GenServer, :call, [:provider_conn, :call, 30_000]}})
          reply -> GenServer.reply(from, reply)
        end

        loop(parent, reply)
    end
  end
end
