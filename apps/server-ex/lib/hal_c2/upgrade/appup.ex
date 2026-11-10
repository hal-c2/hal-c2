defmodule HalC2.Upgrade.Appup do
  @moduledoc """
  The `.appup` of one application between two of its versions, generated from what
  differs between their compiled modules (`HalC2.Upgrade.Release` writes them before
  `systools:make_relup/4` turns them into the release's `relup`).

    * A module new in the version is added, and one it no longer has deleted.
    * A changed supervisor is `{update, M, supervisor}`: it reads its child specs
      again (`HalC2.Upgrade.Tree` then starts, stops and restarts the children that
      changed).
    * A changed module of a process behaviour (`GenServer`, `:gen_statem`, ...) is
      `{update, M, {advanced, []}}`: the processes running it are suspended, migrate
      their state through `code_change/3`, and resume on the new code.
    * Any other changed module is loaded.

  Modules are compared by their code's MD5 (`beam_lib:md5/1`), which stripping a
  release's beams leaves as it is. A changed module names the other changed modules
  it calls as its dependencies, so they load first. Both purges are soft: an install
  that finds a process still running the module's previous old code stops before
  anything changed. A process that waits in a module's code never leaves it, so one
  that may wait for long waits in a `HalC2.Frozen` module instead, which changes only
  at a restart (`HalC2.Upgrade.Release.plan/1`).

  Protocol modules are left out: a release loads their consolidation, which
  `HalC2.Upgrade.Release` loads itself.
  """

  @process_behaviours [
    :gen_server,
    :gen_statem,
    :gen_event,
    :gen_fsm,
    GenServer,
    GenEvent,
    :supervisor_bridge
  ]
  @supervisor_behaviours [:supervisor, Supervisor]

  @type beam :: %{
          md5: binary(),
          behaviours: [module()],
          imports: [module()],
          nif?: boolean(),
          frozen?: boolean()
        }

  @doc "The modules of `ebin` and what an appup needs of each."
  @spec modules(Path.t(), MapSet.t(module())) :: %{module() => beam()}
  def modules(ebin, skip \\ MapSet.new()) do
    for file <- Path.wildcard(Path.join(ebin, "*.beam")),
        mod = String.to_atom(Path.basename(file, ".beam")),
        not MapSet.member?(skip, mod),
        into: %{},
        do: {mod, info(File.read!(file))}
  end

  @doc "What an appup needs of a compiled module."
  @spec info(binary()) :: beam()
  def info(binary) do
    {:ok, {_mod, md5}} = :beam_lib.md5(binary)

    {:ok, {_mod, chunks}} =
      :beam_lib.chunks(binary, [:attributes, :imports], [:allow_missing_chunks])

    attributes = if is_list(chunks[:attributes]), do: chunks[:attributes], else: []
    imports = if is_list(chunks[:imports]), do: chunks[:imports], else: []

    %{
      md5: md5,
      behaviours:
        (Keyword.get_values(attributes, :behaviour) ++ Keyword.get_values(attributes, :behavior))
        |> List.flatten(),
      imports: imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
      nif?: {:erlang, :load_nif, 2} in imports,
      frozen?: Keyword.get(attributes, :hal_c2_frozen) == [true]
    }
  end

  @doc """
  The modules of `new` that differ from, or are missing in, `old`. One `old` has as
  `:unloaded` never ran, so it has nothing to change.
  """
  @spec changed(%{module() => map()}, %{module() => beam()}) :: [module()]
  def changed(old, new) do
    for {mod, %{md5: md5}} <- new, (old[mod] && old[mod].md5) not in [md5, :unloaded], do: mod
  end

  @doc """
  The changed or removed modules processes wait in (`HalC2.Frozen`), which take a
  restart. Processes wait in the running version, so a module that stops being
  frozen, or is dropped, counts too; one new to the release has nobody waiting in
  it yet.
  """
  @spec frozen(%{module() => map()}, %{module() => beam()}) :: [module()]
  def frozen(old, new) do
    changed =
      for mod <- changed(old, new),
          was = old[mod],
          was != nil and (was[:frozen?] == true or new[mod].frozen?),
          do: mod

    removed = for {mod, was} <- old, not Map.has_key?(new, mod), was[:frozen?] == true, do: mod
    changed ++ removed
  end

  @doc """
  The upgrade instructions from `old` to `new` modules, in an order `systools`
  accepts: additions, then updates and loads, then deletions.
  """
  @spec instructions(%{module() => beam()}, %{module() => beam()}) :: [tuple()]
  def instructions(old, new) do
    added = for mod <- Map.keys(new), not Map.has_key?(old, mod), do: mod
    removed = for mod <- Map.keys(old), not Map.has_key?(new, mod), do: mod
    updated = for mod <- changed(old, new), Map.has_key?(old, mod), do: mod
    moving = MapSet.new(added ++ updated)

    Enum.map(Enum.sort(added), &{:add_module, &1}) ++
      Enum.map(Enum.sort(updated), &update(&1, new[&1], moving)) ++
      Enum.map(Enum.sort(removed), &{:delete_module, &1})
  end

  defp update(mod, beam, moving) do
    deps = for dep <- beam.imports, dep != mod, MapSet.member?(moving, dep), do: dep

    cond do
      # `{update, M, supervisor}` with soft purges: supervisors re-read their specs.
      Enum.any?(beam.behaviours, &(&1 in @supervisor_behaviours)) ->
        {:update, mod, :static, :default, {:advanced, []}, :soft_purge, :soft_purge,
         Enum.sort(deps)}

      Enum.any?(beam.behaviours, &(&1 in @process_behaviours)) ->
        {:update, mod, {:advanced, []}, :soft_purge, :soft_purge, Enum.sort(deps)}

      true ->
        {:load_module, mod, :soft_purge, :soft_purge, Enum.sort(deps)}
    end
  end

  @doc "The `.appup` term taking `app` from `from` to `to`."
  @spec appup(String.t(), String.t(), [tuple()]) :: tuple()
  def appup(to, from, instructions),
    do: {String.to_charlist(to), [{String.to_charlist(from), instructions}], []}

  @doc "Writes `term` to `path` the way `file:consult/1` reads it."
  def write_term!(path, term) do
    File.write!(path, :io_lib.format(~c"~tp.~n", [term]))
  end
end
