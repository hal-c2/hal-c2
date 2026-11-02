defmodule HalC2.Hot do
  @moduledoc """
  Live code reload without a release upgrade.

  `reload/2` takes compiled modules, skips the ones whose md5 matches what is loaded,
  suspends every OTP process whose callback module changed, loads the new code, runs
  each process's `code_change/3`, and resumes them. Plain processes (reader loops,
  tasks) move to new code on their next fully qualified call.

  Old code is soft-purged afterwards. A module still referenced by a process that is
  blocked inside old code is reported as `lingering` and can be purged later; it is
  never force-purged, because that would kill the process.

  The VM keeps at most two versions of a module, so the next load of a lingering
  module is refused until its old version is free, naming the processes that hold it.
  A process only leaves old code through a call by module name: a long-lived loop
  that recurses with local calls stays on the version it started with for good, so
  such loops call themselves as `__MODULE__.loop(...)`.

  Only BEAM code loads. A module that loads a NIF is skipped and reported as `native`,
  as are the supervision tree and OTP itself: those need a restart.
  """

  require Logger

  @type beam :: {module, binary}
  @type report :: %{changed: [module], migrated: [pid], lingering: [module], native: [module]}
  @type holder :: {pid, current_function :: mfa | nil}

  @suspend_timeout 5_000

  @doc "Reads every `.beam` file in `dir`."
  @spec beams_from_dir(Path.t()) :: [beam]
  def beams_from_dir(dir) do
    for file <- Path.wildcard(Path.join(dir, "*.beam")) do
      {String.to_atom(Path.basename(file, ".beam")), File.read!(file)}
    end
  end

  @doc "Reloads `beams` on this MC and every connected MC."
  @spec reload_cluster([beam], timeout) :: [{node, {:ok, report} | {:error, term}}]
  def reload_cluster(beams, timeout \\ 30_000) do
    mcs = [node() | Node.list()]

    mcs
    |> :erpc.multicall(__MODULE__, :reload, [beams], timeout)
    |> Enum.zip(mcs)
    |> Enum.map(fn
      {{:ok, result}, mc} -> {mc, result}
      {{kind, reason}, mc} -> {mc, {:error, {kind, reason}}}
    end)
  end

  @doc """
  Loads `beams` on this MC. Processes of a module in `opts[:unmigrated]` keep running
  as they are: a supervisor's new functions load, but its tree only changes at restart.
  """
  @spec reload([beam], keyword) :: {:ok, report} | {:error, term}
  def reload(beams, opts \\ []) do
    {native, changed} =
      beams
      |> Enum.reject(fn {mod, bin} -> loaded_md5(mod) == beam_md5(bin) end)
      |> Enum.split_with(&native?/1)

    mods = Enum.map(changed, &elem(&1, 0))
    old_vsns = Map.new(mods, &{&1, loaded_vsn(&1)})

    case purge_old(mods) do
      [] ->
        procs =
          (mods -- Keyword.get(opts, :unmigrated, []))
          |> processes_using()
          |> suspend(Keyword.get(opts, :suspend_timeout, @suspend_timeout))

        try do
          Enum.each(changed, &load/1)
          for {pid, mod} <- procs, do: :ok = :sys.change_code(pid, mod, old_vsns[mod], :hot)

          {:ok,
           %{
             changed: mods,
             migrated: Enum.map(procs, &elem(&1, 0)),
             lingering: purge_old(mods),
             native: Enum.map(native, &elem(&1, 0))
           }}
        after
          Enum.each(procs, fn {pid, _} -> :sys.resume(pid) end)
        end

      busy ->
        {:error, {:previous_version_still_running, Enum.map(busy, &{&1, holders(&1)})}}
    end
  end

  @doc "Says what a `reload/2` error means, for a developer."
  @spec describe_error(term) :: String.t()
  def describe_error({:previous_version_still_running, busy}) do
    held =
      Enum.map_join(busy, "; ", fn {mod, holders} ->
        if holders == [],
          do: inspect(mod),
          else: "#{inspect(mod)} in " <> Enum.map_join(holders, ", ", &describe_holder/1)
      end)

    "the version before last is still running (#{held}). Those processes never call " <>
      "into newer code, so restart them or the MC"
  end

  def describe_error(reason), do: inspect(reason)

  defp describe_holder({pid, {m, f, a}}), do: "#{inspect(pid)} (#{Exception.format_mfa(m, f, a)})"
  defp describe_holder({pid, nil}), do: inspect(pid)

  @doc """
  Whether `beam` loads a NIF. Loading it again would rerun its `on_load` against the
  native library already in the VM, so it never hot-loads.
  """
  @spec native?(beam) :: boolean
  def native?({_mod, bin}) do
    case :beam_lib.chunks(bin, [:imports]) do
      {:ok, {_, [imports: imports]}} -> {:erlang, :load_nif, 2} in imports
      _ -> false
    end
  end

  # The processes still running, or holding funs of, `mod`'s old version.
  defp holders(mod) do
    for pid <- Process.list(), :erlang.check_process_code(pid, mod) do
      {pid, current_function(pid)}
    end
  end

  defp current_function(pid) do
    case Process.info(pid, :current_function) do
      {:current_function, {m, f, a}} -> {m, f, a}
      _ -> nil
    end
  end

  defp load({mod, bin}) do
    {:module, ^mod} = :code.load_binary(mod, ~c"#{mod}.beam", bin)
  end

  # A module can hold at most one old version, so the previous reload's leftovers must
  # be gone before loading again. Returns the modules that could not be purged.
  defp purge_old(mods), do: Enum.reject(mods, &:code.soft_purge/1)

  defp processes_using(mods) do
    set = MapSet.new(mods)

    for pid <- Process.list(),
        pid != self(),
        {mod, _, _} <- [callback_module(pid)],
        MapSet.member?(set, mod),
        do: {pid, mod}
  end

  defp callback_module(pid) do
    case :proc_lib.translate_initial_call(pid) do
      {mod, _, _} = mfa when is_atom(mod) -> mfa
      _ -> nil
    end
  catch
    _, _ -> nil
  end

  defp suspend(procs, timeout) do
    Enum.filter(procs, fn {pid, mod} ->
      try do
        :sys.suspend(pid, timeout)
        true
      catch
        :exit, reason ->
          Logger.warning(
            "hot reload skipped #{inspect(pid)} (#{inspect(mod)}): #{inspect(reason)}"
          )

          false
      end
    end)
  end

  defp loaded_md5(mod) do
    if :code.is_loaded(mod), do: mod.module_info(:md5)
  end

  defp beam_md5(bin) do
    {:ok, {_mod, md5}} = :beam_lib.md5(bin)
    md5
  end

  defp loaded_vsn(mod) do
    if :code.is_loaded(mod), do: mod.module_info(:attributes)[:vsn]
  end
end
