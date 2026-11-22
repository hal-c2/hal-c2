defmodule HalC2.Test.RunningPlugin do
  @moduledoc """
  Lets a test publish as plugin `id` without building one, and part from the MCs
  watching it: run on the MC whose host is to take it as running.
  """

  def mark(id) do
    host = Process.whereis(HalC2.Plugins)
    :sys.replace_state(host, &put_in(&1.plugins[id].sup, host))
    :ok
  end

  # The connection's end reaches the host as a monitor's signal, which a publish made
  # right after the parting can overtake: so this returns once the host has taken it.
  def part(mc, id, topic) do
    host = Process.whereis(HalC2.Plugins)
    caller = self()
    hook = make_ref()

    told = fn
      state, {:in, {:DOWN, _, :process, _, :noconnection}}, _host ->
        send(caller, hook)
        state

      state, _event, _host ->
        state
    end

    :ok = :sys.install(host, {hook, told, nil})
    _ = Node.disconnect(mc)
    unwatched(host, hook, {{:topic, id, topic, :_}, :_})
    :sys.remove(host, hook)
    :ok
  end

  defp unwatched(host, hook, watch) do
    _ = :sys.get_state(host)

    if :ets.match_object(HalC2.Plugins.Watchers, watch) != [] do
      receive do
        ^hook -> unwatched(host, hook, watch)
      after
        30_000 -> raise "the host still watches for an MC it parted from"
      end
    end
  end
end
