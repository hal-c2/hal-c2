defmodule HalC2.Upgrade.Release do
  @moduledoc """
  Moves the running MC from one release to another in place, with OTP's
  `release_handler`: the installed MC (`HalC2.Upgrade`) and one run from a
  checkout (`HalC2.Upgrade.Dev`) both describe the two releases as a `t:spec/0`
  and come here.

  `plan/1` compares the releases application by application. `install/2` then
  writes each changed application's `.appup` (`HalC2.Upgrade.Appup`), has `systools`
  make the `relup`, registers the new release with the release handler, installs
  it and makes it permanent:

    * The relup suspends the processes that run changed modules, loads the new code,
      migrates their state with `code_change/3` and resumes them. Then the protocol
      consolidation moves to the new release's, and `HalC2.Upgrade.Tree` starts,
      stops and restarts the services whose specs changed.
    * Application environments are replaced from the new release's configuration
      as the relup runs. The release handler reads `sys.config` alone, which leaves
      out `runtime.exs` and what the MC set itself (its home among them), so the
      new release's `sys.config` holds, for the install, the running environment
      with the new configuration and its config providers over it.
    * An install that fails before the point of no return (a process still running
      the old code of a module about to load, say) changes nothing; one that fails
      after it restarts the node on the permanent release, which is still the old
      one (`error_action: restart`).
    * Making it permanent names the release in `start_erl.data`, so the next boot
      runs it. A process moves to a module's new code only when it next calls the
      module by name, and a module keeps one old version: an install that finds a
      process still on code two updates old fails with `{:old_processes, M}` before
      it changes anything. A process that waits in a module's code (a `receive`, or
      a blocking call made from it) never leaves it while it waits, so processes
      that may wait for long wait in `HalC2.Frozen` modules (`HalC2.Pump`).

  What a relup cannot do (a new emulator, OTP applications, code that loads a NIF, or
  a change to a `HalC2.Frozen` module) the caller has the MC restart for; `plan/1`
  names it.
  """

  # SASL is in the release to be started here, at the first update, not at boot.
  @compile {:no_warn_undefined, [:release_handler, :systools]}

  # The relup puts the release it installs here once past its point of no return.
  @past_no_return {__MODULE__, :past_point_of_no_return}

  @typedoc "An application in a release: name, version and the `<app>-<vsn>` directory."
  @type lib :: {atom(), String.t(), Path.t()}

  @typedoc """
  The two releases. `rel_dir` holds `RELEASES` and a directory per version with its
  release file (`rel_file/2`), `start.boot` and `sys.config`. The release handler resolves
  applications against the VM's root (`code:root_dir/0`, the release root of an
  installed MC); ones elsewhere are found by their directory in `from_libs` and
  `to_libs`. `consolidated` are the directories of each release's protocol
  consolidation, or nil.
  """
  @type spec :: %{
          rel_dir: Path.t(),
          from: String.t(),
          to: String.t(),
          from_libs: [lib()],
          to_libs: [lib()],
          from_consolidated: Path.t() | nil,
          to_consolidated: Path.t() | nil,
          otp_apps: MapSet.t(atom())
        }

  @doc """
  What moving between the releases takes: `{:ok, plan}` with each changed
  application's instructions, or `{:restart, reasons}` when a relup cannot do it.
  """
  def plan(spec) do
    skip = consolidated_modules(spec.to_consolidated)
    from = Map.new(spec.from_libs, &{elem(&1, 0), &1})
    to = Map.new(spec.to_libs, &{elem(&1, 0), &1})

    apps =
      for {app, {_, vsn, dir}} <- to,
          {_, old_vsn, old_dir} = from[app] || {app, nil, nil},
          old_vsn != vsn do
        new = HalC2.Upgrade.Appup.modules(Path.join(dir, "ebin"), skip)
        old = if old_dir, do: running_modules(app, old_dir, skip), else: %{}

        %{
          app: app,
          from: old_vsn,
          to: vsn,
          dir: dir,
          instructions: HalC2.Upgrade.Appup.instructions(old, new),
          native: for(mod <- HalC2.Upgrade.Appup.changed(old, new), new[mod].nif?, do: mod),
          frozen:
            for(
              mod <- HalC2.Upgrade.Appup.changed(old, new),
              Map.has_key?(old, mod) and new[mod].frozen?,
              do: mod
            )
        }
      end

    removed = for {app, _} <- from, not Map.has_key?(to, app), do: app
    otp = for %{app: app} <- apps, MapSet.member?(spec.otp_apps, app), do: app

    reasons =
      Enum.filter(
        [
          otp != [] && "OTP applications change (#{Enum.join(Enum.sort(otp), ", ")})",
          (native = Enum.flat_map(apps, & &1.native)) != [] &&
            "#{native |> Enum.map(&inspect/1) |> Enum.join(", ")} load native code",
          (frozen = Enum.flat_map(apps, & &1.frozen)) != [] &&
            "#{frozen |> Enum.map(&inspect/1) |> Enum.join(", ")} change, which processes wait in (HalC2.Frozen)"
        ],
        & &1
      )

    if reasons == [],
      do: {:ok, %{apps: apps, removed: removed, protocols: changed_protocols(spec)}},
      else: {:restart, reasons}
  end

  @doc """
  Installs `spec.to` in place and makes it permanent. `config` is the environment
  the new release's applications get (`config/2`). `{:ok, report}`, or an error:

    * `{:error, reason}` (`describe/1`): refused before anything changed, the MC
      still on `spec.from`.
    * `{:error, {:crashed, why}}`: the script failed past the point of no return, and
      the release handler is restarting the node on the permanent release.
    * `{:error, {:not_permanent, why}}`: `spec.to` runs, but the next boot starts
      the permanent release, still `spec.from`.

  The report
  names the modules that `changed`, those whose old code a process still runs
  (`lingering`), what `HalC2.Upgrade.Tree` did to the `services`, and the ones of
  them that failed to start and so take a restart (`needs_restart`).
  """
  def install(spec, plan, config) do
    to_dir = Path.join(spec.rel_dir, spec.to)

    with :ok <- ensure_handler(spec),
         :ok <- write_appups(plan),
         :ok <- write_relup(spec, plan, to_dir),
         :ok <- unpack(spec) do
      sys = Path.join(to_dir, "sys.config")
      original = File.read(sys)
      # The release handler's own directory, set when SASL started, is not in the
      # configuration the caller read before.
      config = Config.Reader.merge(config, sasl: [releases_dir: String.to_charlist(spec.rel_dir)])
      {literal, kept} = split_literal(config)
      HalC2.Upgrade.Appup.write_term!(sys, literal)
      HalC2.Upgrade.Tree.snapshot()

      :persistent_term.erase(@past_no_return)

      result =
        try do
          installer().(String.to_charlist(spec.to),
            error_action: :restart,
            suspend_timeout: 30_000,
            code_change_timeout: 30_000,
            update_paths: false
          )
        after
          case original do
            {:ok, text} -> File.write!(sys, text)
            _ -> :ok
          end
        end

      past_no_return? = :persistent_term.get(@past_no_return, nil) == String.to_charlist(spec.to)
      :persistent_term.erase(@past_no_return)

      case result do
        {:ok, _from, _descr} ->
          restore(kept)

          case :release_handler.make_permanent(String.to_charlist(spec.to)) do
            :ok ->
              {:ok, report(plan)}

            {:error, reason} ->
              {:error,
               {:not_permanent,
                "#{spec.to} installed but could not be made permanent: #{describe(reason)}"}}
          end

        # The release handler replies so for a script that failed past the point of no
        # return, and then restarts the node on the permanent release itself.
        {:error, reason} when past_no_return? ->
          {:error, {:crashed, describe(reason)}}

        {:error, {:old_processes, mod}} ->
          _ = :release_handler.set_removed(String.to_charlist(spec.to))
          {:error, {:old_processes, mod}}

        {:error, reason} ->
          _ = :release_handler.set_removed(String.to_charlist(spec.to))
          {:error, describe(reason)}

        other ->
          {:error, describe(other)}
      end
    end
  catch
    :exit, reason -> {:error, "the release handler stopped: #{inspect(reason)}"}
  end

  # Tests stand in for the release handler's install: a script that fails past the
  # point of no return restarts the node, which in a test is the test VM.
  defp installer,
    do: Application.get_env(:hal_c2, :install_release, &:release_handler.install_release/2)

  @doc """
  The environment the new release's applications get: what runs now, under the new
  release's `sys.config` (`sys`), under what its config providers (`runtime.exs`)
  make of it.
  """
  def config(running, sys) do
    new =
      case get_in(sys, [:elixir, :config_provider_init]) do
        %{__struct__: Config.Provider, providers: providers} = provider ->
          sys
          |> Config.Reader.merge(provider.extra_config)
          |> then(&Enum.reduce(providers, &1, fn {mod, state}, acc -> mod.load(acc, state) end))

        _ ->
          sys
      end

    Config.Reader.merge(running, new)
  end

  @doc "The environment of every loaded application."
  def running_env do
    for {app, _, _} <- :application.loaded_applications(),
        do: {app, Application.get_all_env(app)}
  end

  # --- release handler -------------------------------------------------------------

  # The release handler reads `RELEASES` once, when SASL starts. The MC starts it at
  # its first update, after writing a `RELEASES` that names the release it runs.
  defp ensure_handler(spec) do
    rel_dir = String.to_charlist(spec.rel_dir)
    started? = List.keymember?(Application.started_applications(), :sasl, 0)

    cond do
      started? and Application.get_env(:sasl, :releases_dir) == rel_dir ->
        :ok

      true ->
        # The handler serves one releases directory, read at its start: one that
        # served another (an MC whose release root moved) starts again on this one.
        if started?, do: :ok = Application.stop(:sasl)
        load_sasl(root())
        File.mkdir_p!(spec.rel_dir)
        File.rm(Path.join(spec.rel_dir, "RELEASES"))

        :ok =
          :release_handler.create_RELEASES(
            String.to_charlist(root()),
            rel_dir,
            String.to_charlist(rel_file(spec.rel_dir, spec.from)),
            lib_dirs(spec, spec.from_libs)
          )

        Application.put_env(:sasl, :releases_dir, rel_dir, persistent: true)

        case Application.ensure_all_started(:sasl) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, "SASL did not start: #{inspect(reason)}"}
        end
    end
  end

  @doc "Whether the release handler runs, and for `rel_dir`."
  def handler_for?(rel_dir) do
    List.keymember?(Application.started_applications(), :sasl, 0) and
      Application.get_env(:sasl, :releases_dir) == String.to_charlist(rel_dir)
  end

  @doc """
  Loads SASL, which a release names (`applications: [sasl: :load]`) and the release
  handler requires in every release; `mix` prunes the code path to the project's
  applications, so a checkout's MC finds it in the OTP `root`.
  """
  def load_sasl(root) do
    # On the code path, not only loaded: the handler loads more of SASL as it goes.
    if :code.where_is_file(~c"release_handler.beam") == :non_existing do
      for ebin <- Path.wildcard(Path.join([root, "lib", "sasl-*", "ebin"])),
          do: :code.add_pathz(String.to_charlist(ebin))
    end

    case Application.load(:sasl) do
      :ok -> :ok
      {:error, {:already_loaded, :sasl}} -> :ok
    end
  end

  # Registers the new release, whose files are in place, as unpacked.
  defp unpack(spec) do
    to = String.to_charlist(spec.to)

    case :release_handler.set_unpacked(
           String.to_charlist(rel_file(spec.rel_dir, spec.to)),
           lib_dirs(spec, spec.to_libs)
         ) do
      {:ok, ^to} ->
        :ok

      {:error, {:existing_release, ^to}} ->
        # A release an earlier attempt left unpacked: forget it and register it again.
        :ok = :release_handler.set_removed(to)
        unpack(spec)

      {:error, reason} ->
        {:error, describe(reason)}
    end
  end

  defp root, do: to_string(:code.root_dir())

  @doc """
  The release file of release `vsn` under `rel_dir`: a mix release names it after the
  release (`hal_c2.rel`), the dev MC's releases `start.rel`.
  """
  def rel_file(rel_dir, vsn) do
    case Path.wildcard(Path.join([rel_dir, vsn, "*.rel"])) do
      [file] -> file
      _ -> Path.join([rel_dir, vsn, "start.rel"])
    end
  end

  # Applications whose directory is not `<root>/lib/<app>-<vsn>`, by the directory
  # their `<app>-<vsn>` is in.
  defp lib_dirs(_spec, libs) do
    lib = Path.join(root(), "lib")

    for {app, vsn, dir} <- libs,
        Path.dirname(dir) != lib,
        do: {app, String.to_charlist(vsn), String.to_charlist(Path.dirname(dir))}
  end

  # --- appups and relup -------------------------------------------------------------

  defp write_appups(plan) do
    for %{app: app, from: from, to: to, dir: dir, instructions: instructions} <- plan.apps,
        from != nil do
      appup = HalC2.Upgrade.Appup.appup(to, from, instructions)
      HalC2.Upgrade.Appup.write_term!(Path.join([dir, "ebin", "#{app}.appup"]), appup)
    end

    :ok
  rescue
    error in File.Error -> {:error, Exception.message(error)}
  end

  defp write_relup(spec, plan, to_dir) do
    paths =
      for {_app, _vsn, dir} <- spec.from_libs ++ spec.to_libs,
          uniq: true,
          do: String.to_charlist(Path.join(dir, "ebin"))

    relup =
      :systools.make_relup(
        String.to_charlist(Path.rootname(rel_file(spec.rel_dir, spec.to))),
        [String.to_charlist(Path.rootname(rel_file(spec.rel_dir, spec.from)))],
        [],
        [:silent, :no_warn_sasl, path: paths, outdir: String.to_charlist(to_dir)]
      )

    case relup do
      {:ok, _relup, _mod, _warnings} -> amend_relup(spec, plan, Path.join(to_dir, "relup"))
      {:error, mod, error} -> {:error, to_string(mod.format_error(error))}
    end
  end

  # After the point of no return the consolidated protocols move to the new
  # release's, and once all code is in, the supervision tree follows. Only OTP
  # functions and the new release's `HalC2.Upgrade.Tree` are called.
  defp amend_relup(spec, plan, path) do
    {:ok, [{to, [{from, descr, script}], down}]} = :file.consult(String.to_charlist(path))

    if Enum.any?(script, &(&1 in [:restart_new_emulator, :restart_emulator])) do
      {:error, "the release needs a new emulator"}
    else
      {before, [:point_of_no_return | rest]} =
        Enum.split_while(script, &(&1 != :point_of_no_return))

      protocols =
        if spec.to_consolidated do
          old =
            if spec.from_consolidated,
              do: [{:apply, {:code, :del_path, [c(spec.from_consolidated)]}}],
              else: []

          old ++
            [{:apply, {:code, :add_patha, [c(spec.to_consolidated)]}}] ++
            Enum.flat_map(plan.protocols, fn mod ->
              [{:apply, {:code, :purge, [mod]}}, {:apply, {:code, :load_file, [mod]}}]
            end)
        else
          []
        end

      purge = for mod <- plan.protocols, do: {:apply, {:code, :soft_purge, [mod]}}

      tree =
        if tree_sync?(spec),
          do: [{:apply, {HalC2.Upgrade.Tree, :sync, []}}],
          else: []

      # Tells `install/3` a failure from here on is the release handler's to restart for.
      past = {:apply, {:persistent_term, :put, [@past_no_return, c(spec.to)]}}
      script = before ++ [:point_of_no_return, past | protocols] ++ rest ++ tree ++ purge
      HalC2.Upgrade.Appup.write_term!(path, {to, [{from, descr, script}], down})
      :ok
    end
  end

  defp c(path), do: String.to_charlist(path)

  # Whether the new release's code has `HalC2.Upgrade.Tree.sync/0`: in `:hal_c2`, or
  # wherever else the release keeps the MC's code.
  defp tree_sync?(spec) do
    Enum.any?(spec.to_libs, fn {app, _, dir} ->
      with false <- MapSet.member?(spec.otp_apps, app),
           {:ok, binary} <- File.read(Path.join([dir, "ebin", "Elixir.HalC2.Upgrade.Tree.beam"])),
           {:ok, {_, [exports: exports]}} <- :beam_lib.chunks(binary, [:exports]) do
        {:sync, 0} in exports
      else
        _ -> false
      end
    end)
  end

  # --- modules --------------------------------------------------------------------------

  # What runs of `app` now: its loaded modules as loaded, the rest as on disk. A
  # module neither loaded nor on disk (a checkout's, `HalC2.Upgrade.Dev`) is
  # `:unloaded`: it loads from the new release when first called.
  defp running_modules(app, dir, skip) do
    on_disk = HalC2.Upgrade.Appup.modules(Path.join(dir, "ebin"), skip)

    listed =
      for mod <- Application.spec(app, :modules) || [], not MapSet.member?(skip, mod), do: mod

    for mod <- Enum.uniq(Map.keys(on_disk) ++ listed), into: %{} do
      md5 =
        cond do
          :code.is_loaded(mod) != false -> mod.module_info(:md5)
          on_disk[mod] -> on_disk[mod].md5
          true -> :unloaded
        end

      {mod, %{md5: md5}}
    end
  end

  defp consolidated_modules(nil), do: MapSet.new()

  defp consolidated_modules(dir) do
    dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> MapSet.new(&String.to_atom(Path.basename(&1, ".beam")))
  end

  defp changed_protocols(%{to_consolidated: nil}), do: []

  defp changed_protocols(spec) do
    for file <- Path.wildcard(Path.join(spec.to_consolidated, "*.beam")),
        mod = String.to_atom(Path.basename(file, ".beam")),
        {:ok, {_, md5}} = :beam_lib.md5(String.to_charlist(file)),
        # One not loaded yet loads from the new consolidation's path when first used.
        :code.is_loaded(mod) != false and mod.module_info(:md5) != md5,
        do: mod
  end

  # --- environment ------------------------------------------------------------------

  @doc false
  # What `file:consult/1` can read back goes in `sys.config`; the rest (functions,
  # pids) is put back after the install. Structs, such as the `Config.Provider` a
  # release keeps in `:elixir`, are maps to it.
  def split_literal(config) do
    literal =
      for {app, env} <- config,
          do: {app, for({key, value} <- env, literal?(value), do: {key, value})}

    kept =
      for {app, env} <- config, {key, value} <- env, not literal?(value), do: {app, key, value}

    {literal, kept}
  end

  defp restore(kept) do
    for {app, key, value} <- kept,
        Application.get_env(app, key) == nil,
        do: Application.put_env(app, key, value)
  end

  defp literal?(value)
       when is_function(value) or is_pid(value) or is_reference(value) or is_port(value),
       do: false

  defp literal?(value) when is_list(value), do: literal_list?(value)
  defp literal?(value) when is_tuple(value), do: Enum.all?(Tuple.to_list(value), &literal?/1)

  defp literal?(%{} = value),
    do: Enum.all?(Map.to_list(value), fn {k, v} -> literal?(k) and literal?(v) end)

  defp literal?(_value), do: true

  defp literal_list?([]), do: true
  defp literal_list?([head | tail]), do: literal?(head) and literal_list?(tail)
  defp literal_list?(tail), do: literal?(tail)

  # --- report -----------------------------------------------------------------------

  defp report(plan) do
    changed =
      for %{instructions: instructions} <- plan.apps,
          instruction <- instructions,
          mod = elem(instruction, 1),
          do: mod

    lingering =
      for {mod, _} <- :code.all_loaded(), :erlang.check_old_code(mod), do: mod

    services = HalC2.Upgrade.Tree.changes()

    %{
      changed: changed ++ plan.protocols,
      lingering: lingering,
      services: services,
      needs_restart: for({:failed, id} <- services, do: id)
    }
  end

  @doc "Why an install failed, for people."
  def describe({:old_processes, mod}) do
    holders = for pid <- Process.list(), :erlang.check_process_code(pid, mod), do: inspect(pid)

    "#{inspect(mod)} is still run on the code of the update before" <>
      if(holders == [], do: "", else: " by #{Enum.join(holders, ", ")}")
  end

  def describe({:code_change_failed, pid, mod, _vsn, reason}),
    do: "#{inspect(mod)} could not migrate #{inspect(pid)}: #{inspect(reason)}"

  def describe({tag, why}) when tag in [:crashed, :not_permanent] and is_binary(why), do: why
  def describe(reason) when is_binary(reason), do: reason
  def describe(reason), do: inspect(reason)
end
