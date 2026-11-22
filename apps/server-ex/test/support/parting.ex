defmodule HalC2.Test.Parting do
  @moduledoc """
  Parts a member from `mc`, and returns once it no longer watches for `mc`: run on
  the member. The connection's end reaches a watched process as a monitor's signal,
  which a change or a question sent right after the parting can overtake, so a test
  that only waits for the node to be gone races it.
  """

  def from_topic(mc, id, topic) do
    watch = {{:topic, id, topic, :_}, :_}
    part(mc, HalC2.Plugins, fn _ -> :ets.match_object(HalC2.Plugins.Watchers, watch) != [] end)
  end

  def from_settings(mc),
    do: part(mc, HalC2.Settings, &watched_from?(&1.watchers, mc))

  def from_stream(mc, stream),
    do: part(mc, stream, &watched_from?(&1.subscribers, mc))

  defp watched_from?(watchers, mc), do: Enum.any?(Map.keys(watchers), &(node(&1) == mc))

  defp part(mc, process, watched?) do
    caller = self()
    hook = make_ref()

    told = fn
      state, {:in, {:DOWN, _, :process, _, :noconnection}}, _process ->
        send(caller, hook)
        state

      state, _event, _process ->
        state
    end

    :ok = :sys.install(process, {hook, told, nil})
    _ = Node.disconnect(mc)
    let_go(process, hook, watched?)
    :sys.remove(process, hook)
    :ok
  end

  defp let_go(process, hook, watched?) do
    if watched?.(:sys.get_state(process)) do
      receive do
        ^hook -> let_go(process, hook, watched?)
      after
        30_000 -> raise "#{inspect(process)} still watches for an MC it parted from"
      end
    end
  end
end
