defmodule HalC2.Watchers do
  @moduledoc """
  The processes a service tells about its changes, as `pid => entry`: the pid's monitor
  and the refs it subscribed under, one per subscription it holds. A client socket
  subscribes once per page showing the service (a page in each window of one client),
  each under a ref of its own, and lets go of that ref only: its unsubscribe goes by
  `:erpc.cast`, which runs in a process of its own and may land after the next
  subscribe, so it must not drop that one. The pid is let go of with its last ref, or
  when it exits.

  A pid that subscribed under refs is sent each message as
  `{:hal_c2_watched, refs, message}`, `refs` the subscriptions it was sent to: one made
  after it was sent (the message can still sit in the mailbox) answered something
  newer. A pid that subscribed without one (`nil`) is sent the message itself.

  An entry kept from before refs (a bare monitor, from a service updated in place) is
  read as a subscription without one.
  """

  # A bare `reference()` is the legacy entry kept from before refs.
  @type entry :: {reference(), MapSet.t()} | reference()
  @type t :: %{pid() => entry}

  @doc "Adds `pid`'s subscription `ref`, monitoring `pid` if it holds no other."
  def add(watchers, pid, ref), do: Map.put(watchers, pid, add_entry(watchers[pid], pid, ref))

  @doc "Lets go of `pid`'s subscription `ref` only; of `pid` with its last."
  def remove(watchers, pid, ref) do
    case watchers do
      %{^pid => entry} ->
        case remove_entry(entry, ref) do
          nil -> Map.delete(watchers, pid)
          entry -> Map.put(watchers, pid, entry)
        end

      _ ->
        watchers
    end
  end

  @doc "Drops `pid` when `monitor` is its monitor going down; anything else is no watcher's."
  def down(watchers, monitor, pid) do
    with %{^pid => entry} <- watchers,
         {^monitor, _refs} <- entry(entry) do
      Map.delete(watchers, pid)
    else
      _ -> watchers
    end
  end

  @doc "Sends `message` to every watcher."
  def notify(watchers, message) do
    Enum.each(watchers, fn {pid, entry} -> tell(pid, entry, message) end)
  end

  @doc "`add/3` for one entry, nil when `pid` has none (a service keeping entries itself)."
  def add_entry(nil, pid, ref), do: {Process.monitor(pid), MapSet.new([ref])}

  def add_entry(entry, _pid, ref) do
    {monitor, refs} = entry(entry)
    {monitor, MapSet.put(refs, ref)}
  end

  @doc "`remove/3` for one entry: nil, and demonitored, once its last ref is gone."
  def remove_entry(entry, ref) do
    {monitor, refs} = entry(entry)
    refs = MapSet.delete(refs, ref)

    if MapSet.size(refs) == 0 do
      Process.demonitor(monitor, [:flush])
      nil
    else
      {monitor, refs}
    end
  end

  @doc "Sends `message` to `pid`, which holds the subscriptions of `entry`."
  def tell(pid, entry, message) do
    {_monitor, refs} = entry(entry)

    if MapSet.size(refs) == 1 and MapSet.member?(refs, nil),
      do: send(pid, message),
      else: send(pid, {:hal_c2_watched, MapSet.to_list(refs), message})
  end

  @doc "`entry` monitoring `pid` anew, its subscriptions kept (a service started again)."
  def monitor_entry(entry, pid), do: {Process.monitor(pid), elem(entry(entry), 1)}

  defp entry({monitor, %MapSet{}} = entry) when is_reference(monitor), do: entry
  defp entry(monitor) when is_reference(monitor), do: {monitor, MapSet.new([nil])}
end
