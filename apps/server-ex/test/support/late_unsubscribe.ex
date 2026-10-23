defmodule HalC2.Test.LateUnsubscribe do
  @moduledoc """
  Stands in for a server under its registered name and forwards it everything, except
  that once `arm/1`ed it holds back `{:unsubscribe, ...}` (or `{:unwatch, ...}`) casts
  until the next `{:subscribe, ...}` (or `{:watch, ...}`) call has gone ahead of them:
  unsubscribes sent by `:erpc.cast`, which runs in a process of its own and so may land
  late. Armed with `hold: true`, it holds that subscribe too until `release/1`, so the
  server can change meanwhile. Armed with `hold: :alone`, it holds only that subscribe,
  and unsubscribes go straight through, as when the subscribe is slow to be sent.
  """

  @subscribe [:subscribe, :watch]
  @unsubscribe [:unsubscribe, :unwatch]

  @doc "Takes `name` over from the process registered under it; answers the gate."
  def install(name) do
    server = Process.whereis(name)
    Process.unregister(name)
    gate = spawn(fn -> loop(server, nil, false, nil, []) end)
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
  `:unsubscribe_held` for each, none left over from an earlier arming. With `hold: true`
  the subscribe waits for `release/1`, and the caller is sent `:subscribe_held` when it
  arrives; with `hold: :alone` so does the subscribe, but nothing else is held.
  """
  def arm(gate, opts \\ []) do
    flush_held()
    send(gate, {:arm, self(), Keyword.get(opts, :hold, false)})

    receive do
      {:armed, ^gate} -> :ok
    after
      5_000 -> exit(:gate_down)
    end
  end

  @doc "Lets the subscribe an `arm(gate, hold: true)` held go ahead, then the unsubscribes."
  def release(gate), do: send(gate, :release)

  defp flush_held do
    receive do
      held when held in [:unsubscribe_held, :subscribe_held] -> flush_held()
    after
      0 -> :ok
    end
  end

  # `hold`: whether the next subscribe waits for `:release` (`:alone` holding nothing
  # else, `:alone_held` once it does); `call`: the one waiting.
  defp loop(server, armer, hold, call, held) do
    receive do
      {:arm, pid, hold} ->
        send(pid, {:armed, self()})
        loop(server, pid, hold, nil, held)

      {:"$gen_cast", request} = cast
      when armer != nil and hold not in [:alone, :alone_held] and
             elem(request, 0) in @unsubscribe ->
        send(armer, :unsubscribe_held)
        loop(server, armer, hold, call, [cast | held])

      {:"$gen_call", _from, request} = call
      when hold in [true, :alone] and elem(request, 0) in @subscribe ->
        send(armer, :subscribe_held)
        loop(server, armer, if(hold == :alone, do: :alone_held, else: false), call, held)

      {:"$gen_call", _from, request} = call when elem(request, 0) in @subscribe ->
        pass(server, call, held)

      :release when call != nil ->
        pass(server, call, held)

      message ->
        send(server, message)
        loop(server, armer, hold, call, held)
    end
  end

  defp pass(server, call, held) do
    send(server, call)
    for cast <- Enum.reverse(held), do: send(server, cast)
    loop(server, nil, false, nil, [])
  end
end
