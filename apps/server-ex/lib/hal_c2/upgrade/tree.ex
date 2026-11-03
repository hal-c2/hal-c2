defmodule HalC2.Upgrade.Tree do
  @moduledoc """
  The MC's supervision tree brought in line with a release just installed in place.

  A release upgrade loads new code into running processes, but a supervisor only
  starts children when it starts: one that re-reads its specs in an upgrade
  (`{update, M, supervisor}`) leaves a new child unstarted and keeps a removed one
  running, and `HalC2.Supervisor`, which `HalC2.Application` starts from a list, reads
  nothing. So before the install `snapshot/0` keeps the specs each static supervisor
  of the MC was started from, and the relup's last instruction, `sync/0` on the new
  code, compares them with the new ones: a child new in the release starts, a removed
  one stops, and one whose spec changed restarts on its new spec. A child that is
  `:temporary` and gone, a boot task that ran and ended, does not run again.

  A supervisor can only add a child at the end of its list, so a child started or
  restarted here comes after the others, wherever the new specs put it. Until the
  MC next boots, the tree stops in that order, and a `rest_for_one` supervisor
  (`HalC2.Streams`) restarts after a crash what follows a child in that order rather
  than the specs'. Putting a child back in place would mean restarting every child
  after it, `HalC2.Web` with its sockets among them, which an upgrade in place is
  there to avoid; `sync/0` logs where the order differs instead.

  The snapshot goes from the old version to the new one through
  `:persistent_term` (`{HalC2.Upgrade.Tree, :before}`), a list of
  `{supervisor_pid, [child_spec]}`; both its key and that shape are a contract
  between versions.
  """

  require Logger

  @key {__MODULE__, :before}
  @changes {__MODULE__, :changes}

  @doc "Keeps the specs of every static supervisor of the MC for `sync/0`."
  def snapshot do
    :persistent_term.put(@key, specs(&own?/1))
    :ok
  end

  @doc """
  Starts, stops and restarts the children whose specs differ from the snapshot,
  and keeps what it did for `changes/0`: `{:started | :stopped | :restarted |
  :failed, id}`, a child that did not start being logged and `:failed`.
  """
  def sync do
    before = Map.new(:persistent_term.get(@key, []))
    :persistent_term.erase(@key)

    # The supervisors snapshotted are the MC's; after the install, which application
    # a module belongs to can name the new release's rather than `:hal_c2`.
    changes =
      for {sup, new} <- specs(fn {pid, _module} -> Map.has_key?(before, pid) end),
          old = Map.get(before, sup),
          change <- sync(sup, old, new),
          do: change

    :persistent_term.put(@changes, changes)
    {:ok, changes}
  end

  @doc "What the last `sync/0` did, once; `[]` when none ran since."
  def changes do
    changes = :persistent_term.get(@changes, [])
    :persistent_term.erase(@changes)
    changes
  end

  @doc false
  def sync(sup, old, new) do
    old_by_id = Map.new(old, &{&1.id, &1})
    new_ids = MapSet.new(new, & &1.id)
    children = Supervisor.which_children(sup)
    # Re-reading its specs in the upgrade (`{update, M, supervisor}`) gives a
    # supervisor the new children as specs that never started.
    known = MapSet.new(children, &elem(&1, 0))
    running = for {id, pid, _, _} <- children, pid != :undefined, into: MapSet.new(), do: id

    removed =
      for %{id: id} <- old, not MapSet.member?(new_ids, id), MapSet.member?(known, id) do
        stop(sup, id)
        if MapSet.member?(running, id), do: {:stopped, id}
      end

    started =
      for %{id: id} = spec <- new do
        case change(old_by_id[id], spec, MapSet.member?(running, id)) do
          nil ->
            # A boot task that ended, back as a spec: it stays ended, and gone.
            if spec.restart == :temporary and MapSet.member?(known, id) and
                 not MapSet.member?(running, id),
               do: stop(sup, id)

            nil

          change ->
            if MapSet.member?(known, id), do: stop(sup, id)
            start(sup, spec, change)
        end
      end

    changes = Enum.filter(removed ++ started, & &1)
    warn_order(sup, new, changes)
    changes
  end

  # `which_children/1` lists the most recently started first.
  defp warn_order(_sup, _new, []), do: :ok

  defp warn_order(sup, new, _changes) do
    live = sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
    specs = for %{id: id} <- new, id in live, do: id

    if Enum.filter(live, &(&1 in specs)) != specs,
      do:
        Logger.warning(
          "#{inspect(sup)} runs its children in another order than its specs until the MC restarts: #{inspect(live)}"
        )

    :ok
  end

  defp start(sup, %{id: id} = spec, change) do
    case Supervisor.start_child(sup, spec) do
      {:ok, _} ->
        {change, id}

      {:ok, _, _} ->
        {change, id}

      error ->
        Logger.error("#{inspect(id)} did not start after the upgrade: #{inspect(error)}")
        {:failed, id}
    end
  end

  defp change(nil, _spec, _present), do: :started
  defp change(same, same, _present), do: nil
  # A boot task that ran and ended stays ended.
  defp change(_old, %{restart: :temporary}, false), do: nil
  defp change(_old, _spec, _present), do: :restarted

  defp stop(sup, id) do
    _ = Supervisor.terminate_child(sup, id)
    _ = Supervisor.delete_child(sup, id)
  end

  # Every supervisor of the MC whose children come from specs it can be asked for
  # again: `HalC2.Supervisor`, from `HalC2.Application.children/0`, and those under
  # it whose own module of the MC implements `init/1`. Dynamic supervisors start what they are
  # asked, and a supervisor started straight from a list cannot say what it would
  # start now.
  defp specs(own?) do
    case Process.whereis(HalC2.Supervisor) do
      nil ->
        []

      root ->
        children =
          if Application.get_env(:hal_c2, :start_mc), do: HalC2.Application.children(), else: []

        [{root, normalize(children)} | nested(root, own?)]
    end
  end

  defp nested(sup, own?) do
    for {_id, pid, :supervisor, _} <- Supervisor.which_children(sup),
        is_pid(pid),
        entry <- own(pid, own?) ++ nested(pid, own?),
        do: entry
  catch
    :exit, _ -> []
  end

  defp own?({_pid, module}), do: Application.get_application(module) == :hal_c2

  defp own(pid, own?) do
    case :sys.get_state(pid, 5_000) do
      state when is_tuple(state) and elem(state, 0) == :state ->
        {module, args} = {elem(state, tuple_size(state) - 2), elem(state, tuple_size(state) - 1)}

        with true <- is_atom(module) and own?.({pid, module}),
             true <- function_exported?(module, :init, 1),
             {:ok, {_flags, children}} <- module.init(args) do
          [{pid, normalize(children)}]
        else
          _ -> []
        end

      _ ->
        []
    end
  catch
    _, _ -> []
  end

  defp normalize(children) do
    for child <- children do
      spec = Supervisor.child_spec(child, [])
      Map.merge(%{restart: :permanent, type: :worker}, spec)
    end
  end
end
