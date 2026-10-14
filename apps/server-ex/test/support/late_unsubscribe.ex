defmodule HalC2.Test.LateUnsubscribe do
  @moduledoc """
  Stands in for a server under its registered name and forwards it everything, except
  that once `arm/1`ed it holds back `{:unsubscribe, ...}` casts until the next
  `{:subscribe, ...}` call has gone ahead of them: unsubscribes sent by `:erpc.cast`,
  which runs in a process of its own and so may land late.
  """

  @doc "Takes `name` over from the process registered under it; answers the gate."
  def install(name) do
    server = Process.whereis(name)
    Process.unregister(name)
    gate = spawn(fn -> loop(server, nil, []) end)
    Process.register(gate, name)
    gate
  end

  @doc "Stops the gate, which frees the name, and waits until it has."
  def uninstall(gate) do
    ref = Process.monitor(gate)
    Process.exit(gate, :kill)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end
  end

  @doc """
  Holds back unsubscribes until the next subscribe; the caller is sent
  `:unsubscribe_held` for each, none left over from an earlier arming.
  """
  def arm(gate) do
    flush_held()
    send(gate, {:arm, self()})

    receive do
      {:armed, ^gate} -> :ok
    after
      5_000 -> exit(:gate_down)
    end
  end

  defp flush_held do
    receive do
      :unsubscribe_held -> flush_held()
    after
      0 -> :ok
    end
  end

  defp loop(server, armer, held) do
    receive do
      {:arm, pid} ->
        send(pid, {:armed, self()})
        loop(server, pid, held)

      {:"$gen_cast", request} = cast when armer != nil and elem(request, 0) == :unsubscribe ->
        send(armer, :unsubscribe_held)
        loop(server, armer, [cast | held])

      {:"$gen_call", _from, request} = call when elem(request, 0) == :subscribe ->
        send(server, call)
        for cast <- Enum.reverse(held), do: send(server, cast)
        loop(server, nil, [])

      message ->
        send(server, message)
        loop(server, armer, held)
    end
  end
end
