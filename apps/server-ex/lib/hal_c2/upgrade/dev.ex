defmodule HalC2.Upgrade.Dev do
  @moduledoc """
  Release upgrades for an MC run from a checkout (`mise run mc:reload`): what
  `mix compile` changed becomes a release the MC installs in place, through the same
  `release_handler` path an installed MC takes (`HalC2.Upgrade.Release`).

  A checkout is not a release, so this makes one from the build, in
  `<state>/dev-releases`, which is the release handler's releases directory:

    * At the first upgrade in a node, the release it runs is described from what
      it has loaded: every application at its version and directory. Applications
      whose directory is not named `<app>-<vsn>` (the checkout's builds, Elixir's
      own) get one there holding only their `.app`, for `systools` to read.
    * Each upgrade copies the applications whose compiled modules differ from what
      runs (and ones the MC's applications newly need) from the caller's build
      (`_build/dev`, of the MC's checkout or a worktree's) to
      `lib/<app>-<vsn>-dev.<n>`, with the protocol consolidation, so later compiles
      cannot change a release under the node. Their `priv` is the build's.
    * The new release has a boot script of its own, which the release handler
      reads the applications' new specifications from, but the node keeps the one
      it booted with, so a restart the release handler makes (`error_action:
      restart`) runs `mix hal_c2.server` again. Its configuration is the running
      environment.

  Releases older than the one running are removed once the new one is permanent.
  """

  alias HalC2.Upgrade.{Appup, Release}

  @compile {:no_warn_undefined, [:release_handler, :systools]}

  @doc """
  Installs what `build` (default: this node's own build) compiled differently from
  what runs: `{:ok, report}` (`HalC2.Upgrade.Release.install/3`), or
  `{:error, reason}`.
  """
  def reload(build \\ nil) do
    build = build || Mix.Project.build_path()
    lib = Path.join(build, "lib")

    if File.dir?(Path.join(lib, "hal_c2/ebin")),
      do: upgrade(lib),
      else: {:error, "#{build} holds no compiled MC"}
  end

  @doc "The releases directory of this MC's checkout upgrades."
  def rel_dir, do: Path.join(HalC2.Paths.state_dir(), "dev-releases")

  defp upgrade(lib) do
    rel_dir = rel_dir()
    first? = not Release.handler_for?(rel_dir)
    if first?, do: File.rm_rf!(rel_dir)
    :ok = Release.load_sasl(to_string(:code.root_dir()))

    from = if first?, do: base_version(), else: current_version()
    from_libs = if first?, do: base(rel_dir), else: read_libs(rel_dir, from)
    n = if(first?, do: 0, else: dev_number(from)) + 1
    to = "#{base_version()}-dev.#{n}"

    from_consolidated = consolidated_path()
    to_consolidated = Path.join([rel_dir, to, "consolidated"])

    protocols = Path.join(lib, "hal_c2/consolidated")
    {to_libs, copied} = new_libs(lib, rel_dir, from_libs, n, protocol_modules(protocols))
    copy_consolidated(protocols, to_consolidated)
    write_release(rel_dir, to, to_libs)

    spec = %{
      rel_dir: rel_dir,
      from: from,
      to: to,
      from_libs: from_libs,
      to_libs: to_libs,
      from_consolidated: from_consolidated,
      to_consolidated: to_consolidated,
      otp_apps: MapSet.new()
    }

    with :ok <- write_boot(rel_dir, to, to_libs),
         {:ok, plan} <- plan(spec),
         {:ok, report} <- install(spec, plan) do
      keep_boot()
      prune(rel_dir, to, to_libs)
      {:ok, report}
    else
      error ->
        for dir <- copied, do: File.rm_rf(dir)
        File.rm_rf(Path.join(rel_dir, to))
        error
    end
  end

  defp plan(spec) do
    case Release.plan(spec) do
      {:ok, plan} -> {:ok, plan}
      {:restart, reasons} -> {:error, "this needs a restart: #{Enum.join(reasons, "; ")}"}
    end
  end

  defp install(spec, plan) do
    case Release.install(spec, plan, Release.config(Release.running_env(), [])) do
      {:ok, report} -> {:ok, report}
      {:error, reason} -> {:error, Release.describe(reason)}
    end
  end

  # --- the running release -----------------------------------------------------------

  defp base_version,
    do: Application.spec(:hal_c2, :vsn) |> to_string() |> String.replace(~r/-dev\.\d+$/, "")

  defp current_version do
    {_name, vsn, _libs, _status} =
      Enum.find(:release_handler.which_releases(), &(elem(&1, 3) == :permanent))

    to_string(vsn)
  end

  defp dev_number(vsn) do
    case Regex.run(~r/-dev\.(\d+)$/, vsn) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  defp read_libs(rel_dir, vsn) do
    {:ok, [libs]} = :file.consult(String.to_charlist(Path.join([rel_dir, vsn, "libs"])))
    for {app, vsn, dir} <- libs, do: {app, to_string(vsn), to_string(dir)}
  end

  # The release this node runs, described from what it has loaded, as `<base>`.
  defp base(rel_dir) do
    libs =
      for {app, _, vsn} <- :application.loaded_applications() do
        vsn = to_string(vsn)
        dir = :code.lib_dir(app)

        dir =
          if is_list(dir) and Path.basename(to_string(dir)) == "#{app}-#{vsn}",
            do: to_string(dir),
            else: stub(rel_dir, app, vsn)

        {app, vsn, dir}
      end

    write_release(rel_dir, base_version(), libs)
    libs
  end

  defp stub(rel_dir, app, vsn) do
    dir = Path.join([rel_dir, "lib", "#{app}-#{vsn}"])
    File.mkdir_p!(Path.join(dir, "ebin"))
    {:ok, keys} = :application.get_all_key(app)
    keys = Keyword.drop(keys, [:env, :id, :maxP, :maxT]) ++ [env: []]
    Appup.write_term!(Path.join([dir, "ebin", "#{app}.app"]), {:application, app, keys})
    dir
  end

  # --- the new release -----------------------------------------------------------------

  # The running applications, with the ones the build compiled differently (or the
  # MC newly needs) copied in at a new version.
  defp new_libs(lib, rel_dir, from_libs, n, protocols) do
    running = Map.new(from_libs, &{elem(&1, 0), &1})

    {libs, copied} =
      for app <- needed(lib, Map.keys(running)), reduce: {running, []} do
        {libs, copied} ->
          source = Path.join(lib, to_string(app))
          ebin = Path.join(source, "ebin")

          if File.dir?(ebin) and
               (not Map.has_key?(running, app) or changed?(app, ebin, protocols)) do
            {vsn, dir} = copy_app(source, rel_dir, app, n)
            {Map.put(libs, app, {app, vsn, dir}), [dir | copied]}
          else
            {libs, copied}
          end
      end

    {Map.values(libs), copied}
  end

  # The applications of the build the MC runs: its own and what they need, which a
  # new dependency joins. Development tools compiled alongside stay out.
  defp needed(lib, running) do
    walk([:hal_c2], MapSet.new(), lib)
    |> Enum.filter(&(&1 in running or File.dir?(Path.join([lib, to_string(&1), "ebin"]))))
  end

  defp walk([], seen, _lib), do: MapSet.to_list(seen)

  defp walk([app | rest], seen, lib) do
    if MapSet.member?(seen, app) do
      walk(rest, seen, lib)
    else
      deps =
        case :file.consult(
               String.to_charlist(Path.join([lib, to_string(app), "ebin", "#{app}.app"]))
             ) do
          {:ok, [{:application, ^app, keys}]} ->
            Keyword.get(keys, :applications, []) ++ Keyword.get(keys, :included_applications, [])

          _ ->
            []
        end

      walk(deps ++ rest, MapSet.put(seen, app), lib)
    end
  end

  # Protocols are compared as consolidated (`copy_consolidated/2`), not here: what
  # runs of them is the consolidation, never an application's own beam.
  defp changed?(app, ebin, protocols) do
    on_disk =
      for file <- Path.wildcard(Path.join(ebin, "*.beam")),
          {:ok, {mod, md5}} = :beam_lib.md5(String.to_charlist(file)),
          not MapSet.member?(protocols, mod),
          into: %{},
          do: {mod, md5}

    listed =
      for mod <- Application.spec(app, :modules) || [],
          not MapSet.member?(protocols, mod),
          do: mod

    Enum.sort(Map.keys(on_disk)) != Enum.sort(listed) or
      Enum.any?(on_disk, fn {mod, md5} ->
        :code.is_loaded(mod) != false and mod.module_info(:md5) != md5
      end)
  end

  defp protocol_modules(dir) do
    dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> MapSet.new(&String.to_atom(Path.basename(&1, ".beam")))
  end

  defp copy_app(source, rel_dir, app, n) do
    {:ok, [{:application, ^app, keys}]} =
      :file.consult(String.to_charlist(Path.join([source, "ebin", "#{app}.app"])))

    vsn = "#{keys[:vsn]}-dev.#{n}"
    dir = Path.join([rel_dir, "lib", "#{app}-#{vsn}"])
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.cp_r!(Path.join(source, "ebin"), Path.join(dir, "ebin"))

    Appup.write_term!(
      Path.join([dir, "ebin", "#{app}.app"]),
      {:application, app, Keyword.put(keys, :vsn, String.to_charlist(vsn))}
    )

    priv = Path.join(source, "priv")
    if File.exists?(priv), do: File.ln_s!(resolve(priv), Path.join(dir, "priv"))
    {vsn, dir}
  end

  defp resolve(path) do
    case File.read_link(path) do
      {:ok, target} -> Path.expand(target, Path.dirname(path))
      _ -> path
    end
  end

  defp copy_consolidated(source, target) do
    File.rm_rf!(target)
    File.mkdir_p!(target)
    if File.dir?(source), do: File.cp_r!(source, target)
  end

  defp consolidated_path do
    Enum.find_value(:code.get_path(), fn dir ->
      dir = to_string(dir)
      if Path.basename(dir) == "consolidated", do: dir
    end)
  end

  defp write_release(rel_dir, vsn, libs) do
    dir = Path.join(rel_dir, vsn)
    File.mkdir_p!(dir)
    started = MapSet.new(Application.started_applications(), &elem(&1, 0))

    apps =
      for {app, app_vsn, _dir} <- Enum.sort(libs) do
        type = if MapSet.member?(started, app) or not loaded?(app), do: :permanent, else: :load
        {app, String.to_charlist(app_vsn), type}
      end

    rel =
      {:release, {~c"hal_c2", String.to_charlist(vsn)}, {:erts, :erlang.system_info(:version)},
       apps}

    Appup.write_term!(Path.join(dir, "start.rel"), rel)

    Appup.write_term!(
      Path.join(dir, "libs"),
      for({app, v, d} <- libs, do: {app, String.to_charlist(v), String.to_charlist(d)})
    )

    Appup.write_term!(Path.join(dir, "sys.config"), [])
  end

  # The release handler takes each application's new specification (its version,
  # modules and default environment) from the boot script, so the new release gets
  # one of its own. The node keeps booting the way it started: `keep_boot/0`.
  defp write_boot(rel_dir, vsn, libs) do
    dir = Path.join(rel_dir, vsn)
    path = for {_app, _vsn, lib_dir} <- libs, do: String.to_charlist(Path.join(lib_dir, "ebin"))

    case :systools.make_script(String.to_charlist(Path.join(dir, "start")), [
           :silent,
           :no_warn_sasl,
           :no_module_tests,
           path: path,
           outdir: String.to_charlist(dir)
         ]) do
      :ok -> :ok
      {:ok, _module, _warnings} -> :ok
      {:error, module, reason} -> {:error, to_string(module.format_error(reason))}
      :error -> {:error, "systools could not make the boot script of #{vsn}"}
    end
  end

  # Making a release permanent points `init` at its boot script for the next
  # restart; a checkout's MC restarts as it was started (`mix hal_c2.server`).
  defp keep_boot do
    boot =
      case :init.get_argument(:boot) do
        {:ok, [[boot | _] | _]} -> boot
        _ -> String.to_charlist(Path.join([to_string(:code.root_dir()), "bin", "start"]))
      end

    config =
      case :init.get_argument(:config) do
        {:ok, [[config | _] | _]} -> config
        _ -> false
      end

    :ok = :init.make_permanent(boot, config)
  end

  defp loaded?(app), do: List.keymember?(:application.loaded_applications(), app, 0)

  # Releases before the permanent one, and the copies only they used.
  defp prune(rel_dir, current, libs) do
    keep = MapSet.new(libs, &elem(&1, 2))

    for {_name, vsn, _libs, status} <- :release_handler.which_releases(),
        to_string(vsn) != current,
        status != :permanent do
      :release_handler.set_removed(vsn)
      File.rm_rf(Path.join(rel_dir, to_string(vsn)))
    end

    for dir <- Path.wildcard(Path.join([rel_dir, "lib", "*-dev.*"])),
        not MapSet.member?(keep, dir),
        do: File.rm_rf(dir)

    :ok
  end
end
