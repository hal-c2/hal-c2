defmodule HalC2.Upgrade do
  @moduledoc """
  An MC moving to another HAL-C2 version (`server.updateServer`), in place when it can.

  A version arrives as a bundle: a release's `lib/`, `releases/<vsn>/` and ERTS,
  with the `upgrade.json` manifest `mix release` writes (`HalC2.Upgrade.Source` finds
  one). Its directories join the running release's (versioned ones never change once
  written), and the MC moves to it with an OTP release upgrade
  (`HalC2.Upgrade.Release`): `release_handler` installs a `relup` generated from what
  differs between the two releases, the processes running changed code migrate their
  state through `code_change/3`, the supervision tree takes in the services that
  changed, and the release is made permanent, so the next boot runs it. Nothing
  restarts; sockets and provider sessions stay up. An install that fails puts the MC
  back on the release it ran (`HalC2.Upgrade.Release`).

  A bundle built for another platform, or on another patch of the Erlang runtime,
  installs too when only HAL-C2's own code changes: its release is the running one
  with that code (`HalC2.Upgrade.Code`), on the runtime the MC already has.

  What a release upgrade cannot do, a new emulator (another OTP release, emulator
  flags), OTP applications or code that loads a NIF changing, or a running
  release from before release upgrades, is a restart: `releases/start_erl.data`
  names the new release and the MC exits with status 75, which `bin/hal-c2-service`
  answers by starting it again. An install in place that is refused before it changes
  anything (a process still on code an update before) ends in the same restart. Turns
  cut off go on where the project asks for that (`HalC2.Orchestration.Recovery`). The
  previous `start_erl.data` is kept beside it until the new version boots; if it
  cannot, `bin/hal-c2-service` puts it back and starts the old version again.

  The outcome is kept in `<home>/upgrades/outcome.json` and reported with the MC's next
  `ready`, so a client that asked can tell success from a rollback. One update runs at
  a time; another asked for meanwhile is refused.
  """

  use GenServer

  require Logger

  # `bin/hal-c2-service` starts the MC again when it exits with this status. The exit
  # itself is `:restart_exit` in the app env (`System.stop/1` unless a test swaps it).
  @continue "continueRunningThreads"
  @restart_status 75
  @members_timeout :timer.minutes(5)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The version this MC runs: its application's, until an upgrade in place moves it
  (`{HalC2.Upgrade, :version}` in `:persistent_term`, which tests set too).
  """
  def version do
    :persistent_term.get({__MODULE__, :version}, nil) ||
      to_string(Application.spec(:hal_c2, :vsn))
  end

  @doc "The release this MC runs from, or nil when it runs from a checkout."
  def release_root, do: System.get_env("RELEASE_ROOT")

  @doc """
  `serverSelfUpdate` for the descriptor: the desktop app that started this MC updates
  it, and otherwise only a release can install a version.
  """
  def capability do
    cond do
      HalC2.DesktopUpdate.available?() -> "desktop-managed"
      release_root() -> "hot-upgrade"
      true -> nil
    end
  end

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

  An MC the desktop app started is updated with the app (`HalC2.DesktopUpdate`),
  which cancels the update when `owner` (the caller when nil) goes away.
  """
  def update(input, progress \\ nil, owner \\ nil) do
    if HalC2.DesktopUpdate.available?(),
      do: HalC2.DesktopUpdate.update(progress, owner),
      else: hot_update(input, progress)
  end

  # No deadline of its own: every stage of an update has one (a download that stops
  # receiving, a peer that stops answering, a preflight), and a slow download that
  # keeps receiving goes on as long as it needs.
  defp hot_update(input, progress \\ nil) do
    GenServer.call(__MODULE__, {:update, input, progress}, :infinity)
  catch
    :exit, {:noproc, _} -> failure("This MC cannot update itself.")
    :exit, reason -> failure("The update stopped: #{inspect(reason)}")
  end

  @doc """
  Updates to `version` from its bundle archive at `path` on this machine
  (`mix hal_c2.upgrade --release`), as `update/2` does from a fetched one. The MCs
  clustered with this one update first, taking the bundle from it before this one
  restarts. How each went is the result's `members`.
  """
  def update_from(path, version) do
    if File.regular?(path) do
      # Before the bundle reaches the cache: the boot prune would take it, a version
      # not yet installed being nothing it keeps.
      :ok = await_pruned()
      :ok = HalC2.Upgrade.Source.put(version, platform(), path)
      input = %{"targetVersion" => version}
      members = update_members(Node.list(), input)
      with {:ok, result} <- hot_update(input), do: {:ok, Map.put(result, "members", members)}
    else
      failure("#{path} is not a bundle.")
    end
  end

  @doc """
  `cluster.update`: has every connected member on another version update to the one
  this MC runs, taking the bundle from it. `{:ok, version, [%{"mc", "from", "outcome"}]}`
  with the version sent, or `{:error, :not_a_release}` when this MC runs from a checkout
  and has no bundle.
  """
  def update_members do
    if release_root() do
      target = version()
      others = for mc <- Node.list(), (from = version_of(mc)) != target, do: {mc, from}
      if others != [], do: :ok = HalC2.Upgrade.Source.ensure_own(target)
      outcomes = update_members(Enum.map(others, &elem(&1, 0)), %{"targetVersion" => target})

      {:ok, target,
       for(
         {{_mc, from}, outcome} <- Enum.zip(others, outcomes),
         do: Map.put(outcome, "from", from)
       )}
    else
      {:error, :not_a_release}
    end
  end

  defp version_of(mc) do
    :erpc.call(mc, __MODULE__, :version, [], 5_000)
  catch
    _, _ -> nil
  end

  # A member that restarts to take the new version says so (`complete`) before it drops
  # its connections; one that goes down without saying may have lost the network or
  # crashed while installing, so its update is unconfirmed.
  #
  # They all get `@members_timeout` between them, which leaves this MC's own update
  # its time within what `mix hal_c2.upgrade --release` waits for an answer.
  defp update_members(members, input) do
    # Off the caller, which is left none of the members' messages.
    Task.async(fn -> await_members(members, input) end) |> Task.await(:infinity)
  end

  defp await_members(members, input) do
    deadline = System.monotonic_time(:millisecond) + @members_timeout
    for mc <- members, do: Node.monitor(mc, true)
    started = :erpc.multicall(members, __MODULE__, :start, [input, self()], 15_000)

    for {mc, reply} <- Enum.zip(members, started) do
      outcome =
        with {:ok, :ok} <- reply do
          receive do
            # A restart is complete before it happens: only a member that loaded the
            # version in place runs it already.
            {:hal_c2_server_update, ^mc, %{"type" => "complete"}} ->
              if version_of(mc) == input["targetVersion"], do: "updated", else: "restarting on it"

            {:hal_c2_server_update, ^mc, {:error, %{"reason" => reason}}} ->
              reason

            {:nodedown, ^mc} ->
              "the connection dropped before it finished"
          after
            max(deadline - System.monotonic_time(:millisecond), 0) -> "has not finished"
          end
        else
          _ -> "cannot be updated from another machine"
        end

      %{"mc" => Atom.to_string(mc), "outcome" => outcome}
    end
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
        case update(input, pid, pid) do
          {:ok, result} -> %{"type" => "complete", "result" => result}
          {:error, error} -> {:error, error}
        end

      send(pid, {:hal_c2_server_update, node(), event})
    end)

    :ok
  end

  @doc """
  Installs what `mix compile` changed as a release upgrade, for MCs run from source
  (`mix hal_c2.upgrade --dev`, `mise run mc:reload`): `HalC2.Upgrade.Dev`.

  `build` is the build directory (`_build/dev`) of the checkout that asks, a
  worktree's say; nil is the one this MC started from. `{:ok, %{changed, needs_restart,
  lingering}}` or `{:error, reason}`.
  """
  def reload_checkout(build \\ nil) do
    with {:ok, report} <- HalC2.Upgrade.Dev.reload(build) do
      __MODULE__.after_upgrade()
      {:ok, report}
    end
  end

  # A release upgrade stands in for a restart, so it takes in what the MC otherwise
  # looks at only at boot: plugins put in or changed in the plugins directory, and the
  # GitHub CLI's sign-in. Called by name after the upgrade, so it runs the new code.
  @doc false
  def after_upgrade do
    if Process.whereis(HalC2.Plugins), do: HalC2.Plugins.rescan()
    if Application.get_env(:hal_c2, :start_mc), do: HalC2.Git.use_gh_for_github()
    :ok
  end

  @doc "The outcome of the last update this MC finished, for `ready` events."
  def outcome, do: :persistent_term.get({__MODULE__, :outcome}, nil)

  @doc """
  How `bundle` installs over the release `running` describes: `{:in_place, how}`,
  `:release` for this platform's bundle and `:code` for another platform's, which only
  changes HAL-C2's own code, or `{:restart, reasons}` when only a restart can take it.
  What the release upgrade itself cannot do (`HalC2.Upgrade.Release.plan/1`) is
  known once the bundle's files are in place.
  """
  def plan(bundle, running \\ running_manifest()) do
    target = manifest(bundle)

    reasons =
      if running && target do
        [
          !running["releaseUpgrades"] && "the running release predates release upgrades",
          !target["releaseUpgrades"] && "the bundle predates release upgrades",
          running["otpRelease"] != target["otpRelease"] && "OTP changes",
          running["vmArgs"] != target["vmArgs"] && "the emulator's flags change"
        ]
      else
        [
          running == nil && "the running release has no upgrade manifest",
          target == nil && "the bundle has no upgrade manifest"
        ]
      end
      |> Enum.filter(& &1)

    own? = target && target["platform"] in [nil, platform()] && running["erts"] == target["erts"]

    cond do
      reasons != [] -> {:restart, reasons}
      own? -> {:in_place, :release}
      foreign = foreign_reasons(running, target) -> {:restart, foreign}
      true -> {:in_place, :code}
    end
  end

  # Another platform's bundle, or one built on another patch of the Erlang runtime,
  # carries its native code and its runtime, so in place it only lends its HAL-C2 code
  # to the running release, which must otherwise stay as it is. A restart takes the
  # bundle whole.
  defp foreign_reasons(running, target) do
    reasons =
      Enum.filter(
        [
          target["code"] == nil && "the bundle does not name HAL-C2's own code",
          changed_dependencies(running, target),
          running["packages"] && running["packages"] != target["packages"] &&
            "platform packages change",
          running["config"] != target["config"] && "configuration changes"
        ],
        & &1
      )

    if reasons != [], do: reasons
  end

  # A dependency this MC runs another version of, or not at all. Ones the new
  # version no longer has stay until a restart.
  defp changed_dependencies(running, target) do
    changed =
      for {name, vsn} <- target["dependencies"] || %{},
          (running["applications"] || %{})[name] != vsn,
          do: name

    changed != [] && "dependencies change (#{changed |> Enum.sort() |> Enum.join(", ")})"
  end

  # --- server --------------------------------------------------------------------

  # The state is nil while idle, and `{:running, monitor, caller}` while an update runs.
  @impl true
  def init(nil) do
    # Before the services after this one: the agents, terminals and pulls they start
    # reach GitHub through gh too. It asks SSH off this process, so they do not wait.
    _ = HalC2.Git.use_gh_for_github()
    # Before Recovery and its continuations start, which read it without a call.
    :persistent_term.put({__MODULE__, :continue_threads}, pending_continue?())
    {:ok, nil, {:continue, :outcome}}
  end

  # Whether the update this boot comes from asked the turns it cut off to continue.
  # The outcome file under the MC's own data directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp pending_continue? do
    with {:ok, text} <- File.read(outcome_path()),
         {:ok, %{"status" => "restarting"} = pending} <- JSON.decode(text) do
      pending[@continue] == true
    else
      _ -> false
    end
  end

  # A restart for an update ends here: the version that booted says how it went.
  @impl true
  def handle_continue(:outcome, state) do
    # A version installed while the service ran (`hal-c2 update`, answered no) runs now.
    if System.get_env("HAL_C2_SERVICE") == "1", do: HalC2.Service.started(version())

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

      # `init/1` kept whether the turns the restart cut off continue this boot; the
      # recorded outcome drops it.
      record(outcome)
      if root = release_root(), do: settle_start(root, booted)
    else
      {:ok, %{} = done} -> :persistent_term.put({__MODULE__, :outcome}, done)
      _ -> :ok
    end

    if root = release_root(), do: start_prune(root)
    {:noreply, state}
  end

  # Every start from a release, however it was started (the service, an SSH host
  # running the installed version directly, by hand), removes what no version uses.
  # Off this server, so removing gigabytes of old versions holds up no update request;
  # one at a time, under `HalC2.Upgrade.Prune`'s name, which `await_pruned/0` waits on.
  # An update itself waits for it before it fetches (`run/2`): the prune's keep set
  # knows nothing of the version an update is installing, so the two never overlap.
  defp start_prune(root) do
    {:ok, pid} = Task.start(fn -> receive(do: (:go -> prune(root))) end)

    try do
      Process.register(pid, HalC2.Upgrade.Prune)
      send(pid, :go)
    rescue
      ArgumentError -> Process.exit(pid, :kill)
    end
  end

  @doc "Returns once this boot has read its outcome and removed the versions nothing uses."
  def await_pruned do
    if Process.whereis(__MODULE__), do: :sys.get_state(__MODULE__)

    with pid when is_pid(pid) <- Process.whereis(HalC2.Upgrade.Prune) do
      ref = Process.monitor(pid)
      receive(do: ({:DOWN, ^ref, _, _, _} -> :ok))
    end

    :ok
  end

  defp prune(root) do
    case HalC2.Upgrade.Prune.run(root, version()) do
      {:ok, _removed} -> :ok
      {:error, reason} -> Logger.info("old versions are kept: #{reason}")
    end
  rescue
    error -> Logger.warning("removing old versions failed: #{Exception.message(error)}")
  end

  @doc """
  Whether the update this MC restarted for asked for the turns it cut off to continue
  (`continueRunningThreads`), whatever their projects' `continueThreadsAfterServerUpdate`.
  Set as this server starts, before Recovery does.
  """
  def continue_threads?, do: :persistent_term.get({__MODULE__, :continue_threads}, false)

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

  defp run(%{"targetVersion" => target} = input, progress) do
    from = version()
    root = release_root()
    id = "hot-upgrade-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    cond do
      root == nil ->
        failure("This MC runs from a checkout; update it with `mix hal_c2.upgrade`.")

      not exact?(target) ->
        failure("#{inspect(target)} is not an exact version; name one such as 1.2.3.")

      target == from ->
        failure("This MC already runs #{target}.")

      true ->
        # Before the fetch reads the target's cached bundle or installed release:
        # the boot prune, still removing old versions off this server, may be
        # about to take exactly those. It is bounded by its own removals.
        :ok = await_pruned()
        notify(progress, "downloading")

        with {:ok, bundle} <- HalC2.Upgrade.Source.fetch(target, platform()) do
          notify(progress, "installing")

          outcome =
            %{"id" => id, "fromVersion" => from, "targetVersion" => target}
            |> Map.merge(Map.take(input, [@continue]))

          result = %{"targetVersion" => target, "method" => "hot-upgrade", "updateId" => id}
          plan = plan(bundle)

          case stage(plan, bundle, root, target) do
            :ok -> activate(plan, {bundle, root}, from, target, outcome, result)
            {:error, reason} -> failure("Installing #{target} failed: #{reason}")
          end
        end
    end
  end

  defp run(_input, _progress), do: failure("No target version was given.")

  # A version names one release; "latest", a range or "1.2" would leave the MC to guess.
  defp exact?(target), do: is_binary(target) and match?({:ok, _}, Version.parse(target))

  # The bundle's release beside the running one, under `root`.
  defp stage(plan, bundle, root, target) do
    manifest = manifest(bundle)

    cond do
      manifest["version"] != target ->
        {:error, "the bundle is not #{target}"}

      plan == {:in_place, :code} ->
        HalC2.Upgrade.Code.install(bundle, root, running_manifest(), manifest)

      match?({:restart, _}, plan) and manifest["platform"] not in [nil, platform()] ->
        {:restart, reasons} = plan

        {:error,
         "it needs a restart (#{Enum.join(reasons, "; ")}), which takes the #{platform()} release, and only the #{manifest["platform"]} one was found"}

      true ->
        install(bundle, root, target)
    end
  end

  defp activate({:restart, reasons}, staged, _from, target, outcome, result),
    do: restart(staged, target, outcome, result, Enum.join(reasons, "; "))

  defp activate({:in_place, how}, {bundle, root} = staged, from, target, outcome, result) do
    spec = release_spec(root, from, target)

    case HalC2.Upgrade.Release.plan(spec) do
      {:restart, reasons} ->
        restart(staged, target, outcome, result, Enum.join(reasons, "; "))

      {:ok, plan} ->
        config =
          HalC2.Upgrade.Release.config(
            HalC2.Upgrade.Release.running_env(),
            sys_config(root, target)
          )

        # A node the release handler restarts mid-install comes back on `from`,
        # and says so (`handle_continue/2`).
        record(Map.put(outcome, "status", "restarting"))

        case HalC2.Upgrade.Release.install(spec, plan, config) do
          {:ok, report} ->
            with {:error, reason} <- if(how == :release, do: copy_bin(bundle, root), else: :ok),
                 do: Logger.warning("#{target}'s launchers did not go in: #{reason}")

            moved(target, outcome, %{"status" => "committed"})

            Logger.info(
              "upgraded in place to #{target} (#{length(report.changed)} modules, #{length(report.lingering)} with old code still running)"
            )

            {:ok, result}

          # The release handler restarts the node on `from` itself; `start_erl.data`
          # still names it, so the next boot is `from` whichever way it comes.
          {:error, {:crashed, why}} ->
            why = "installing in place failed partway: #{why}"

            Logger.error(
              "#{target} did not install in place, so the MC restarts on #{from}: #{why}"
            )

            record(Map.merge(outcome, %{"status" => "rolled-back", "reason" => why}))
            failure("Installing #{target} failed, and the MC restarts on #{from}: #{why}")

          # `target` runs until the MC restarts, which starts `from`.
          {:error, {:not_permanent, why}} ->
            why = "#{why}; the MC runs it until it restarts, which starts #{from}"
            Logger.error(why)
            moved(target, outcome, %{"status" => "failed", "reason" => why})
            failure(why)

          {:error, reason} ->
            why = "installing in place failed: #{HalC2.Upgrade.Release.describe(reason)}"

            Logger.warning(
              "#{target} did not install in place, so the MC restarts into it: #{why}"
            )

            record(Map.merge(outcome, %{"status" => "rolled-back", "reason" => why}))
            restart(staged, target, outcome, result, why)
        end
    end
  end

  # This MC runs `target`'s code now.
  defp moved(target, outcome, status) do
    :persistent_term.put({__MODULE__, :version}, target)
    HalC2.Cluster.version_changed()
    HalC2.Shell.announce()
    record(Map.merge(outcome, status))
    announce()
    __MODULE__.after_upgrade()
  end

  # The staged version is asked first whether it can run here (`HalC2.Upgrade.Preflight`);
  # until it says yes nothing the next start reads has changed, so a refusal leaves
  # the MC as it was. Its launchers go in only then.
  defp restart({bundle, root}, target, outcome, result, why) do
    with true <- System.get_env("HAL_C2_SERVICE") == "1" || :not_service,
         :ok <- HalC2.Upgrade.Preflight.run(bundle, target),
         {:launchers, :ok} <- {:launchers, copy_bin(bundle, root)} do
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
      :not_service ->
        failure(
          "#{target} needs a restart (#{why}), and this MC was not started by bin/hal-c2-service, which would start it again. " <>
            "Remote updates that restart the MC need the background service: run `hal-c2-mc install` on the server machine."
        )

      {:launchers, {:error, reason}} ->
        failure("Installing #{target}'s launchers failed: #{reason}")

      {:error, reason} ->
        Logger.warning("#{target} cannot run on this machine, so the MC stays on it: #{reason}")
        failure("#{target} cannot run on this machine: #{reason}")
    end
  end

  # --- install ---------------------------------------------------------------------

  defp install(bundle, root, target) do
    with true <-
           File.dir?(Path.join([bundle, "releases", target])) ||
             {:error, "the bundle is not #{target}"},
         :ok <- copy_new(bundle, root, "lib"),
         :ok <- copy_new(bundle, root, "releases"),
         :ok <- copy_new(bundle, root, ".") do
      :ok
    end
  end

  # Versioned directories never change once written; only missing ones are copied, each
  # whole or not at all (`.partial` until it is), so an install cut off is redone.
  defp copy_new(bundle, root, dir) do
    sources =
      if dir == ".",
        do: Path.wildcard(Path.join(bundle, "erts-*")),
        else: for(entry <- File.ls!(Path.join(bundle, dir)), do: Path.join([bundle, dir, entry]))

    for source <- sources,
        File.dir?(source),
        target = Path.join([root, dir, Path.basename(source)]) |> Path.expand(),
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

  # The launchers of a bundle this MC checked, into its own release root.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_bin(bundle, root) do
    for file <- Path.wildcard(Path.join([bundle, "bin", "*"])) do
      target = Path.join([root, "bin", Path.basename(file)])
      File.mkdir_p!(Path.dirname(target))
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

  # The boot after an update restart: the release kept from before it names the one
  # that booted when this is a rollback the service did not make (the release handler
  # restarting a failed install in the VM, say), and goes back so the next boot is
  # this one too.
  defp settle_start(root, booted) do
    previous = previous_start(root)

    with {:ok, text} <- File.read(previous),
         [_erts, ^booted] <- String.split(text) do
      File.rename!(previous, start_data(root))
    else
      _ -> File.rm(previous)
    end
  end

  # The release before an update restart, for `bin/hal-c2-service` to go back to.
  defp previous_start(root), do: start_data(root) <> ".previous"

  # --- release upgrade -----------------------------------------------------------------

  # The running release and the new one, both under `root`.
  defp release_spec(root, from, to) do
    manifest = manifest_of(root, to) || %{}
    deps = Map.keys(manifest["dependencies"] || %{})

    %{
      rel_dir: Path.join(root, "releases"),
      from: from,
      to: to,
      from_libs: libs(root, from),
      to_libs: libs(root, to),
      from_consolidated: consolidated(root, from),
      to_consolidated: consolidated(root, to),
      otp_apps:
        for(
          {app, _} <- manifest["applications"] || %{},
          app not in deps and app not in (manifest["code"] || []),
          into: MapSet.new(),
          do: String.to_atom(app)
        )
    }
  end

  defp libs(root, vsn) do
    {:ok, [{:release, _name, _erts, apps}]} =
      :file.consult(
        String.to_charlist(HalC2.Upgrade.Release.rel_file(Path.join(root, "releases"), vsn))
      )

    for app <- apps do
      {name, app_vsn} = {elem(app, 0), to_string(elem(app, 1))}
      {name, app_vsn, Path.join([root, "lib", "#{name}-#{app_vsn}"])}
    end
  end

  defp consolidated(root, vsn) do
    dir = Path.join([root, "releases", vsn, "consolidated"])
    if File.dir?(dir), do: dir
  end

  defp sys_config(root, vsn) do
    case :file.consult(String.to_charlist(Path.join([root, "releases", vsn, "sys.config"]))) do
      {:ok, [config]} -> config
      _ -> []
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

  # --- outcome -----------------------------------------------------------------------

  # Only a restart still to happen carries `continueRunningThreads`: one that does not
  # happen, or has, leaves no marks behind.
  defp record(outcome) do
    outcome =
      if outcome["status"] == "restarting", do: outcome, else: Map.delete(outcome, @continue)

    File.mkdir_p!(Path.dirname(outcome_path()))
    File.write!(outcome_path(), JSON.encode!(outcome))

    if outcome["status"] != "restarting",
      do: :persistent_term.put({__MODULE__, :outcome}, outcome)
  end

  @doc """
  A desktop app update that failed after it was committed (`HalC2.DesktopUpdate`):
  recorded as the last outcome, and told to the clients watching this MC's config.
  """
  def desktop_failed(outcome) do
    # A disk that cannot take it (the install may have failed for that very reason)
    # must not keep clients from hearing; only a restart forgets it then.
    try do
      record(outcome)
    rescue
      error in File.Error ->
        Logger.warning("Could not save a failed desktop update: #{Exception.message(error)}")
        :persistent_term.put({__MODULE__, :outcome}, outcome)
    end

    announce()
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
