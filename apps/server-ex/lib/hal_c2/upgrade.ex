defmodule HalC2.Upgrade do
  @moduledoc """
  An MC moving to another HAL-C2 version (`server.updateServer`), in place when it can.

  A version arrives as a bundle: a release's `lib/`, `releases/<vsn>/` and ERTS,
  with the `upgrade.json` manifest `mix release` writes (`HalC2.Upgrade.Source` finds
  one). The MC compares it with the manifest of the release it runs:

    * Same runtime, applications, native libraries and configuration, and no
      supervisor among the changed modules: the bundle is installed next to the
      running release, code paths move to it, and `HalC2.Hot` loads the changed
      modules, migrating running processes through `code_change/3`. Nothing
      restarts; sockets and provider sessions stay up.
    * Anything else: the bundle is installed, `releases/start_erl.data` names it,
      and the MC exits with status 75, which `bin/hal-c2-service` answers by starting
      it again, now on the new version. Turns cut off go on where the project asks
      for that (`HalC2.Orchestration.Recovery`). The previous `start_erl.data` is kept
      beside it until the new version boots; if it cannot, `bin/hal-c2-service` puts it
      back and starts the old version again.

  Either way the next boot runs the new version. The outcome is kept in
  `<home>/upgrades/outcome.json` and reported with the MC's next `ready`, so a
  client that asked can tell success from a rollback. One update runs at a time;
  another asked for meanwhile is refused.
  """

  use GenServer

  require Logger

  # `bin/hal-c2-service` starts the MC again when it exits with this status. The exit
  # itself is `:restart_exit` in the app env (`System.stop/1` unless a test swaps it).
  @restart_status 75

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The version this MC runs, including one loaded in place."
  def version do
    :persistent_term.get({__MODULE__, :version}, nil) ||
      to_string(Application.spec(:hal_c2, :vsn))
  end

  @doc "The release this MC runs from, or nil when it runs from a checkout."
  def release_root, do: System.get_env("RELEASE_ROOT")

  @doc "`serverSelfUpdate` for the descriptor: only a release can install a version."
  def capability, do: if(release_root(), do: "hot-upgrade")

  @doc "This machine's bundle platform, e.g. `darwin-arm64`."
  def platform do
    os = :os.type() |> elem(1) |> to_string()
    arch = :erlang.system_info(:system_architecture) |> to_string()

    arch =
      cond do
        arch =~ ~r/aarch64|arm64/ -> "arm64"
        arch =~ ~r/x86_64|amd64/ -> "x64"
        true -> arch
      end

    "#{os}-#{arch}"
  end

  @doc """
  `server.updateServer`: moves this MC to `targetVersion`. `progress` gets
  `{:hal_c2_server_update, mc, %{"type" => "progress", "stage" => stage}}` as it goes. `{:ok, ServerSelfUpdateResult}` once
  the new version runs (hot) or is about to (restart).
  """
  def update(input, progress \\ nil) do
    GenServer.call(__MODULE__, {:update, input, progress}, :timer.minutes(15))
  catch
    :exit, {:noproc, _} -> failure("This MC cannot update itself.")
  end

  @doc """
  `server.updateServerWithProgress`: runs `update/2` off the caller and sends `pid`
  `{:hal_c2_server_update, mc, event}` with `ServerSelfUpdateProgressEvent`s, ending
  with `complete`, or `{:error, ServerSelfUpdateError}`.
  """
  def start(input, pid) do
    # Progress comes from this MC's updater and the end from this task, both on
    # this MC, so they reach `pid` in order.
    Task.start(fn ->
      event =
        case update(input, pid) do
          {:ok, result} -> %{"type" => "complete", "result" => result}
          {:error, error} -> {:error, error}
        end

      send(pid, {:hal_c2_server_update, node(), event})
    end)

    :ok
  end

  @doc """
  Loads what changed in this MC's own checkout after `mix compile`, for MCs run
  from source (`mix hal_c2.upgrade --dev`). Supervisors are left alone: they only take
  effect at start, so they are reported to restart for instead.
  """
  def reload_checkout do
    dirs =
      for path <- :code.get_path(),
          path = to_string(path),
          String.contains?(path, "/_build/"),
          do: path

    # The first directory on the code path that has a module is where it loads from:
    # a consolidated protocol shadows its plain build in the application's ebin.
    beams =
      for dir <- dirs,
          file <- Path.wildcard(Path.join(dir, "*.beam")),
          mod = String.to_atom(Path.basename(file, ".beam")),
          :code.is_loaded(mod) do
        {mod, file}
      end
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.map(fn {mod, file} -> {mod, File.read!(file)} end)
      |> Enum.filter(fn {mod, bin} -> loaded_md5(mod) != beam_md5(bin) end)

    {restart, hot} = Enum.split_with(beams, &restart_module?/1)

    with {:ok, report} <- HalC2.Hot.reload(hot) do
      {:ok, Map.put(report, :needs_restart, Enum.map(restart, &elem(&1, 0)))}
    end
  end

  @doc "The outcome of the last update this MC finished, for `ready` events."
  def outcome, do: :persistent_term.get({__MODULE__, :outcome}, nil)

  @doc """
  What installing `bundle` would take: `:hot` with the modules that change, or
  `{:restart, reasons}`.
  """
  def plan(bundle, running \\ running_manifest()) do
    target = manifest(bundle)

    reasons =
      [
        running == nil && "the running release has no upgrade manifest",
        target == nil && "the bundle has no upgrade manifest",
        running && target && running["erts"] != target["erts"] && "the Erlang runtime changes",
        running && target && running["otpRelease"] != target["otpRelease"] && "OTP changes",
        running && target &&
          Map.keys(running["applications"] || %{}) != Map.keys(target["applications"] || %{}) &&
          "applications are added or removed",
        running && target && running["nifs"] != target["nifs"] && "native libraries change",
        running && target && running["config"] != target["config"] && "configuration changes"
      ]
      |> Enum.filter(& &1)

    if reasons == [] do
      changed = changed_modules(bundle, target)

      case Enum.filter(changed, &restart_module?(&1)) do
        [] -> {:hot, Enum.map(changed, &elem(&1, 0))}
        supervisors -> {:restart, ["#{inspect(elem(hd(supervisors), 0))} supervises processes"]}
      end
    else
      {:restart, reasons}
    end
  end

  # --- server --------------------------------------------------------------------

  # The state is nil while idle, and `{:running, monitor, caller}` while an update runs.
  @impl true
  def init(nil) do
    {:ok, nil, {:continue, :outcome}}
  end

  # A restart for an update ends here: the version that booted says how it went.
  @impl true
  def handle_continue(:outcome, state) do
    # A version installed while the service ran (`hal-c2 update`, answered no) runs now.
    if System.get_env("HAL_C2_SERVICE") == "1", do: HalC2.Service.clear_restart_pending()

    with {:ok, text} <- File.read(outcome_path()),
         {:ok, %{"status" => "restarting"} = pending} <- JSON.decode(text) do
      booted = version()

      outcome =
        if booted == pending["targetVersion"],
          do: Map.merge(pending, %{"status" => "committed"}),
          else:
            Map.merge(pending, %{
              "status" => "rolled-back",
              "reason" => "The MC started #{booted} instead of #{pending["targetVersion"]}."
            })

      record(outcome)
      if root = release_root(), do: File.rm(previous_start(root))
    else
      {:ok, %{} = done} -> :persistent_term.put({__MODULE__, :outcome}, done)
      _ -> :ok
    end

    {:noreply, state}
  end

  # One update at a time: it runs off this process, and a request while it does is
  # refused rather than queued behind it.
  @impl true
  def handle_call({:update, _input, _progress}, _from, {:running, _, _} = state),
    do: {:reply, failure("A server update is already in progress."), state}

  def handle_call({:update, input, progress}, from, _state) do
    {_pid, ref} = spawn_monitor(fn -> exit({:shutdown, {:update, run(input, progress)}}) end)
    {:noreply, {:running, ref, from}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, reason}, {:running, ref, from}) do
    reply =
      case reason do
        {:shutdown, {:update, reply}} -> reply
        reason -> failure("The update stopped: #{inspect(reason)}")
      end

    GenServer.reply(from, reply)
    {:noreply, nil}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run(%{"targetVersion" => target}, progress) do
    from = version()
    root = release_root()
    id = "hot-upgrade-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    cond do
      root == nil ->
        failure("This MC runs from a checkout; update it with `mix hal_c2.upgrade`.")

      target == from ->
        failure("This MC already runs #{target}.")

      true ->
        notify(progress, "downloading")

        with {:ok, bundle} <- HalC2.Upgrade.Source.fetch(target, platform()) do
          notify(progress, "installing")
          outcome = %{"id" => id, "fromVersion" => from, "targetVersion" => target}
          result = %{"targetVersion" => target, "method" => "hot-upgrade", "updateId" => id}

          case install(bundle, root, target) do
            :ok -> activate(plan(bundle), bundle, root, target, outcome, result)
            {:error, reason} -> failure("Installing #{target} failed: #{reason}")
          end
        end
    end
  end

  defp run(_input, _progress), do: failure("No target version was given.")

  defp activate({:hot, modules}, bundle, root, target, outcome, result) do
    case load(bundle, root, target, modules) do
      :ok ->
        set_start_version(root, target)
        :persistent_term.put({__MODULE__, :version}, target)
        record(Map.put(outcome, "status", "committed"))
        announce()
        Logger.info("upgraded in place to #{target} (#{length(modules)} modules)")
        {:ok, result}

      {:error, reason} ->
        # Whatever loaded stays; the next start runs the new version fully.
        restart(root, target, outcome, result, "loading in place failed: #{inspect(reason)}")
    end
  end

  defp activate({:restart, reasons}, _bundle, root, target, outcome, result),
    do: restart(root, target, outcome, result, Enum.join(reasons, "; "))

  defp restart(root, target, outcome, result, why) do
    if System.get_env("HAL_C2_SERVICE") == "1" do
      File.cp!(start_data(root), previous_start(root))
      set_start_version(root, target)
      record(Map.put(outcome, "status", "restarting"))
      Logger.info("restarting into #{target}: #{why}")
      # After the reply has gone out. Tests stand in for `System.stop/1` with `:restart_exit`.
      exit = Application.get_env(:hal_c2, :restart_exit, &System.stop/1)

      spawn(fn ->
        Process.sleep(500)
        exit.(@restart_status)
      end)

      {:ok, result}
    else
      failure(
        "#{target} needs a restart (#{why}), and this MC was not started by bin/hal-c2-service, which would start it again."
      )
    end
  end

  # --- install ---------------------------------------------------------------------

  @doc false
  def install(bundle, root, target) do
    with true <-
           File.dir?(Path.join([bundle, "releases", target])) ||
             {:error, "the bundle is not #{target}"},
         :ok <- copy_new(bundle, root, "lib"),
         :ok <- copy_new(bundle, root, "releases"),
         :ok <- copy_new(bundle, root, "."),
         :ok <- copy_bin(bundle, root) do
      :ok
    end
  end

  # Versioned directories never change once written; only missing ones are copied.
  defp copy_new(bundle, root, "." = _dir) do
    for erts <- Path.wildcard(Path.join(bundle, "erts-*")),
        target = Path.join(root, Path.basename(erts)),
        not File.exists?(target),
        do: File.cp_r!(erts, target)

    :ok
  end

  defp copy_new(bundle, root, dir) do
    for entry <- File.ls!(Path.join(bundle, dir)),
        source = Path.join([bundle, dir, entry]),
        File.dir?(source),
        target = Path.join([root, dir, entry]),
        not File.exists?(target) do
      staged = target <> ".partial"
      File.rm_rf!(staged)
      File.cp_r!(source, staged)
      File.rename!(staged, target)
    end

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp copy_bin(bundle, root) do
    for file <- Path.wildcard(Path.join([bundle, "bin", "*"])) do
      target = Path.join([root, "bin", Path.basename(file)])
      File.cp!(file, target <> ".new")
      File.rename!(target <> ".new", target)
    end

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp set_start_version(root, target) do
    path = start_data(root)
    [erts | _] = path |> File.read!() |> String.split()
    erts = (manifest_of(root, target) || %{})["erts"] || erts
    File.write!(path <> ".new", "#{erts} #{target}\n")
    File.rename!(path <> ".new", path)
  end

  defp start_data(root), do: Path.join([root, "releases", "start_erl.data"])

  # The release before an update restart, for `bin/hal-c2-service` to go back to.
  defp previous_start(root), do: start_data(root) <> ".previous"

  # --- load in place -----------------------------------------------------------------

  # Code paths move to the new release's directories, so modules loaded later come
  # from it too, then the changed modules load and running processes migrate.
  defp load(bundle, root, target, modules) do
    for {app, vsn} <- (manifest(bundle) || %{})["applications"] || %{} do
      ebin = Path.join([root, "lib", "#{app}-#{vsn}", "ebin"])
      if File.dir?(ebin), do: :code.replace_path(String.to_atom(app), String.to_charlist(ebin))
    end

    consolidated = Path.join([root, "releases", target, "consolidated"])

    for path <- :code.get_path(),
        path = to_string(path),
        String.ends_with?(path, "/consolidated") and path != consolidated,
        do: :code.del_path(String.to_charlist(path))

    if File.dir?(consolidated), do: :code.add_patha(String.to_charlist(consolidated))

    wanted = MapSet.new(modules)
    beams = for {mod, _} = beam <- beams(bundle), MapSet.member?(wanted, mod), do: beam

    case HalC2.Hot.reload(beams) do
      {:ok, _report} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- manifests and modules -------------------------------------------------------------

  defp running_manifest do
    with root when is_binary(root) <- release_root(), do: manifest_of(root, version())
  end

  defp manifest_of(root, vsn) do
    with {:ok, text} <- File.read(Path.join([root, "releases", vsn, "upgrade.json"])),
         {:ok, manifest} <- JSON.decode(text),
         do: manifest,
         else: (_ -> nil)
  end

  @doc false
  def manifest(bundle) do
    case Path.wildcard(Path.join([bundle, "releases", "*", "upgrade.json"])) do
      [path | _] ->
        with {:ok, text} <- File.read(path),
             {:ok, manifest} <- JSON.decode(text),
             do: manifest,
             else: (_ -> nil)

      [] ->
        nil
    end
  end

  # Every compiled module in the bundle's applications and protocol consolidation.
  defp beams(bundle) do
    for dir <-
          Path.wildcard(Path.join([bundle, "lib", "*", "ebin"])) ++
            Path.wildcard(Path.join([bundle, "releases", "*", "consolidated"])),
        file <- Path.wildcard(Path.join(dir, "*.beam")) do
      {String.to_atom(Path.basename(file, ".beam")), File.read!(file)}
    end
  end

  defp changed_modules(bundle, _target) do
    for {mod, bin} = beam <- beams(bundle),
        loaded_md5(mod) != nil,
        loaded_md5(mod) != beam_md5(bin),
        do: beam
  end

  # Supervisors, and the application that lists the tree, only take effect at start.
  defp restart_module?({HalC2.Application, _bin}), do: true

  defp restart_module?({_mod, bin}) do
    case :beam_lib.chunks(bin, [:attributes]) do
      {:ok, {_, [attributes: attributes]}} ->
        behaviours = Keyword.get_values(attributes, :behaviour) |> List.flatten()
        :supervisor in behaviours or Supervisor in behaviours

      _ ->
        false
    end
  end

  defp loaded_md5(mod), do: if(:code.is_loaded(mod), do: mod.module_info(:md5))

  defp beam_md5(bin) do
    {:ok, {_mod, md5}} = :beam_lib.md5(bin)
    md5
  end

  # --- outcome -----------------------------------------------------------------------

  defp record(outcome) do
    File.mkdir_p!(Path.dirname(outcome_path()))
    File.write!(outcome_path(), JSON.encode!(outcome))

    if outcome["status"] != "restarting",
      do: :persistent_term.put({__MODULE__, :outcome}, outcome)
  end

  # Clients watching this MC's config see its new descriptor and the outcome.
  defp announce, do: HalC2.Settings.notify_upgraded(outcome())

  defp outcome_path,
    do: Path.join([HalC2.Paths.data_dir(), "upgrades", "outcome.json"])

  defp notify(nil, _stage), do: :ok

  defp notify(pid, stage),
    do: send(pid, {:hal_c2_server_update, node(), %{"type" => "progress", "stage" => stage}})

  defp failure(reason), do: {:error, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}}
end
