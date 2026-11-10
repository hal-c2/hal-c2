defmodule HalC2.WorkspaceLease do
  @moduledoc """
  One holder at a time for a folder and everything under it. Storage cleanup holds
  a worktree's lease from its last look until the folder is gone, and a terminal
  holds it while it starts (`HalC2.Terminal`), so a terminal never starts in a folder
  being deleted and a removal never misses a terminal that just started.

  Two folders overlap when one holds the other. A caller waits while a holder or an
  earlier waiter overlaps its folder, so waiters on one folder go in the order they
  asked. A holder or waiter that dies lets go.

  `{:repository, git_dir}` is held apart from every folder: changes to one repository
  that must not interleave take their turns on it (`HalC2.Vcs`).
  """

  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Runs `fun` holding the lease for `path`, waiting first for the holders of
  overlapping folders. Without the lease server (a unit test that starts only part
  of an MC) nothing else contends for the folder and `fun` runs at once.
  """
  def with_lease(path, fun) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        fun.()

      server ->
        ref = GenServer.call(server, {:acquire, key(path)}, :infinity)

        try do
          fun.()
        after
          GenServer.cast(server, {:release, ref})
        end
    end
  end

  @doc "The folders held now, as their leases see them (real paths)."
  def held, do: GenServer.call(__MODULE__, :held)

  # Real paths, so a folder reached through a link is the folder it links to.
  defp key({:repository, _} = repository), do: repository

  defp key(path) do
    path = Path.expand(path)
    with({:ok, real} <- HalC2.Paths.real(path), do: real, else: (_ -> path))
  end

  @impl true
  def init(nil), do: {:ok, %{held: %{}, waiting: []}}

  @impl true
  def handle_call({:acquire, path}, {pid, _} = from, state) do
    ref = Process.monitor(pid)
    waiter = %{ref: ref, path: path, from: from}

    if free?(path, state.held, state.waiting) do
      {:reply, ref, put_in(state.held[ref], path)}
    else
      {:noreply, %{state | waiting: state.waiting ++ [waiter]}}
    end
  end

  def handle_call(:held, _from, state), do: {:reply, Map.values(state.held), state}

  @impl true
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, let_go(state, ref)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, let_go(state, ref)}

  def handle_info(_other, state), do: {:noreply, state}

  defp let_go(state, ref) do
    state = %{
      state
      | held: Map.delete(state.held, ref),
        waiting: Enum.reject(state.waiting, &(&1.ref == ref))
    }

    grant(state.waiting, [], state.held)
  end

  # Lets in, in order, each waiter no holder and no waiter ahead of it overlaps.
  defp grant([], ahead, held), do: %{held: held, waiting: Enum.reverse(ahead)}

  defp grant([waiter | rest], ahead, held) do
    if free?(waiter.path, held, ahead) do
      GenServer.reply(waiter.from, waiter.ref)
      grant(rest, ahead, Map.put(held, waiter.ref, waiter.path))
    else
      grant(rest, [waiter | ahead], held)
    end
  end

  defp free?(path, held, waiting) do
    not Enum.any?(Map.values(held), &overlap?(&1, path)) and
      not Enum.any?(waiting, &overlap?(&1.path, path))
  end

  defp overlap?(a, b) when is_binary(a) and is_binary(b), do: within?(a, b) or within?(b, a)
  defp overlap?(a, b), do: a == b

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
