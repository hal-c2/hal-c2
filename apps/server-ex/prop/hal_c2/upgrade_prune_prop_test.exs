defmodule HalC2.UpgradePrunePropTest do
  @moduledoc """
  `HalC2.Upgrade.Prune` removing old versions from a release root in a scratch home,
  between installs of versions that share applications and runtimes, changes to the
  version that starts next and the one the service would go back to, processes
  running from a version, and removals cut off midway.

  The model: a prune removes exactly the installed versions that do not run, start
  next, serve as the way back, run in some process or were installed within the hour,
  and with them every application, runtime and cached bundle that no version left uses
  and that is older than an hour. What a removal cut off left is cleared, and is never
  taken for an installed version. When the MC cannot tell which version starts next,
  it removes nothing.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Upgrade.Appup
  alias HalC2.Upgrade.Prune
  alias HalC2.Upgrade.Source

  @versions ~w(1.0.0 1.1.0 1.2.0 1.3.0)
  @shared ~w(1 2)
  # Runtimes no test VM runs, so the prune's own-runtime rule never applies.
  @erts ~w(0.1 0.2)

  property "a prune removes exactly what nothing can use", numtests: HalC2.Prop.numtests(40) do
    forall cmds <- resize(12, commands(__MODULE__)) do
      trap_exit do
        setup()

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            teardown()
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------------

  # `installed` maps each installed version to its application directories and
  # runtime; `libs`, `erts` and `caches` map each directory on disk to whether it is
  # less than an hour old; `start` and `previous` are the versions in
  # `start_erl.data` and its `.previous`; `held` the versions a process runs from.
  def initial_state,
    do: %{
      installed: %{},
      libs: %{},
      erts: %{},
      caches: %{},
      start: nil,
      previous: nil,
      held: MapSet.new()
    }

  def command(state) do
    installed = Map.keys(state.installed)

    frequency(
      [
        {4,
         {:call, __MODULE__, :install,
          [oneof(@versions), oneof(@shared), oneof(@erts), boolean()]}},
        {2, {:call, __MODULE__, :starts, [oneof(@versions)]}},
        {1, {:call, __MODULE__, :previous, [oneof([nil | @versions])]}},
        {1, {:call, __MODULE__, :hold, [oneof(@versions)]}},
        {1, {:call, __MODULE__, :let_go, [oneof(@versions)]}},
        {3, {:call, __MODULE__, :prune, [oneof(@versions)]}}
      ] ++
        if(installed == [],
          do: [],
          else: [{1, {:call, __MODULE__, :interrupt, [oneof(installed)]}}]
        )
    )
  end

  def precondition(state, {:call, _, :install, [version | _]}),
    do: not Map.has_key?(state.installed, version)

  def precondition(state, {:call, _, :interrupt, [version]}),
    do: Map.has_key?(state.installed, version)

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :install, [version, shared, erts, recent]}) do
    libs = ["hal_c2-#{version}", "common-#{shared}"]

    %{
      state
      | installed: Map.put(state.installed, version, %{libs: libs, erts: "erts-#{erts}"}),
        libs: Enum.reduce(libs, state.libs, &Map.put(&2, &1, recent)),
        erts: Map.put(state.erts, "erts-#{erts}", recent),
        caches: Map.put(state.caches, version, recent)
    }
  end

  def next_state(state, _result, {:call, _, :starts, [version]}),
    do: %{state | start: version}

  def next_state(state, _result, {:call, _, :previous, [version]}),
    do: %{state | previous: version}

  def next_state(state, _result, {:call, _, :hold, [version]}),
    do: %{state | held: MapSet.put(state.held, version)}

  def next_state(state, _result, {:call, _, :let_go, [version]}),
    do: %{state | held: MapSet.delete(state.held, version)}

  # The removal renamed the release and stopped: the version is no longer installed,
  # and what it alone used is still on disk.
  def next_state(state, _result, {:call, _, :interrupt, [version]}),
    do: %{state | installed: Map.delete(state.installed, version)}

  def next_state(%{start: nil} = state, _result, {:call, _, :prune, _}), do: state

  def next_state(state, _result, {:call, _, :prune, [running]}) do
    keep = keep(state, running)
    installed = Map.filter(state.installed, fn {v, _} -> v in keep end)
    used_libs = for {_, %{libs: libs}} <- installed, lib <- libs, into: MapSet.new(), do: lib
    used_erts = for {_, %{erts: erts}} <- installed, into: MapSet.new(), do: erts
    cached = MapSet.union(keep, MapSet.new(Map.keys(installed)))

    %{
      state
      | installed: installed,
        libs: Map.filter(state.libs, fn {d, recent} -> recent or d in used_libs end),
        erts: Map.filter(state.erts, fn {d, recent} -> recent or d in used_erts end),
        caches: Map.filter(state.caches, fn {v, recent} -> recent or v in cached end)
    }
  end

  def postcondition(%{start: nil}, {:call, _, :prune, _}, {result, _disk}),
    do: match?({:error, _}, result)

  def postcondition(state, {:call, _, :prune, _} = call, {result, disk}) do
    after_prune = next_state(state, nil, call)
    gone = Map.keys(state.installed) -- Map.keys(after_prune.installed)
    result == {:ok, Enum.sort(gone)} and disk == expected_disk(after_prune)
  end

  def postcondition(_state, _call, _result), do: true

  defp keep(state, running) do
    # Only an installed version can be running or new; a release a removal already
    # renamed is neither.
    recent = for {v, _} <- state.installed, state.caches[v], do: v
    held = for v <- state.held, Map.has_key?(state.installed, v), do: v

    MapSet.new(
      [running, state.start | List.wrap(state.previous)] ++
        held ++ recent
    )
  end

  # What `disk/0` shows once a prune has run: no removal is left half-done.
  defp expected_disk(state),
    do: %{
      releases: state.installed |> Map.keys() |> Enum.sort(),
      libs: state.libs |> Map.keys() |> Enum.sort(),
      erts: state.erts |> Map.keys() |> Enum.sort(),
      caches: state.caches |> Map.keys() |> Enum.sort()
    }

  # --- commands ---------------------------------------------------------------------

  # Installs `version` on applications `hal_c2-<version>` and `common-<shared>` and
  # runtime `erts`, every directory either just written or two hours old.
  def install(version, shared, erts, recent) do
    root = root()
    rel = Path.join([root, "releases", version])
    File.mkdir_p!(rel)

    Appup.write_term!(
      Path.join(rel, "hal_c2.rel"),
      {:release, {~c"hal_c2", String.to_charlist(version)}, {:erts, String.to_charlist(erts)},
       [{:hal_c2, String.to_charlist(version)}, {:common, String.to_charlist(shared)}]}
    )

    File.write!(Path.join(rel, "start.boot"), "")

    libs =
      for lib <- ["hal_c2-#{version}", "common-#{shared}"] do
        dir = Path.join([root, "lib", lib])
        File.mkdir_p!(Path.join(dir, "ebin"))
        dir
      end

    erts_dir = Path.join(root, "erts-#{erts}")
    File.mkdir_p!(Path.join(erts_dir, "bin"))
    cache = Source.cache_dir(version)
    File.mkdir_p!(cache)
    File.write!(Path.join(cache, "bundle.tar.gz"), "")

    age = if recent, do: 0, else: 7200

    for path <- [rel, erts_dir, cache | libs],
        do: File.touch!(path, System.os_time(:second) - age)

    :ok
  end

  def starts(version),
    do: File.write!(Path.join([root(), "releases", "start_erl.data"]), "0.1 #{version}\n")

  def previous(nil), do: File.rm_rf!(Path.join([root(), "releases", "start_erl.data.previous"]))

  def previous(version),
    do:
      File.write!(
        Path.join([root(), "releases", "start_erl.data.previous"]),
        "0.1 #{version}\n"
      )

  def hold(version), do: Process.put(:held, MapSet.put(held(), version))
  def let_go(version), do: Process.put(:held, MapSet.delete(held(), version))

  # A removal cut off after renaming the release, with part of it already deleted.
  def interrupt(version) do
    releases = Path.join(root(), "releases")
    gone = Path.join(releases, version <> ".removing")
    File.rm_rf!(gone)
    File.rename!(Path.join(releases, version), gone)
    File.rm!(Path.join(gone, "start.boot"))
  end

  def prune(running) do
    root = root()
    args = for v <- held(), do: "beam.smp -- -boot #{root}/releases/#{v}/start"
    Application.put_env(:hal_c2, :upgrade_processes, fn -> {:ok, args} end)
    {Prune.run(root, running), disk()}
  end

  # What is on disk, `.removing` leftovers included under the name they would have.
  defp disk do
    root = root()

    %{
      releases: dirs(Path.join(root, "releases")),
      libs: dirs(Path.join(root, "lib")),
      erts: root |> dirs() |> Enum.filter(&String.starts_with?(&1, "erts-")),
      caches: dirs(Path.dirname(Source.cache_dir("x")))
    }
  end

  defp dirs(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.filter(&File.dir?(Path.join(dir, &1))) |> Enum.sort()
      {:error, :enoent} -> []
    end
  end

  defp held, do: Process.get(:held, MapSet.new())

  defp root, do: Path.join(Process.get(:home), "release")

  # --- case setup -------------------------------------------------------------------

  defp setup do
    home = HalC2.Prop.scratch_home("upgrade-prune")
    Process.put(:home, home)
    Process.delete(:held)
    File.mkdir_p!(Path.join([home, "release", "releases"]))
  end

  defp teardown do
    Application.delete_env(:hal_c2, :upgrade_processes)
    Application.delete_env(:hal_c2, :home)
    File.rm_rf(Process.get(:home))
  end
end
