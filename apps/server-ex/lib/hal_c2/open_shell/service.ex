defmodule HalC2.OpenShell.Service do
  @moduledoc """
  The OpenShell gateway as a service of its own: a systemd user unit on Linux
  (`hal-c2-openshell-<instance>.service`), a LaunchAgent on macOS
  (`io.github.halc2.openshell.<instance>`). It is not part of the MC's unit, so the
  gateway and its sandboxes outlive an MC restart or crash, and the MC never holds
  the runtime socket itself.

  Each HAL-C2 home on the machine has a service of its own, named for its
  `HalC2.OpenShell.instance/0`. A unit under this home's name that runs a gateway
  from another home's directory was not written here: `install/1`, `stop/0`,
  `start/0` and `uninstall/0` refuse it (`[unit-not-ours]`) and leave it as it is.

  Either unit starts the gateway through `HalC2.OpenShell.Config.command/2`, in an
  environment of its own: neither the systemd user manager's environment nor
  launchd's (`launchctl setenv`) reaches it.

  Beside it, a reaper runs `hal-c2-service openshell reap --root <dir>` every
  minute (`hal-c2-openshell-<instance>-reap.timer`,
  `io.github.halc2.openshell.<instance>.reap`): OpenShell 0.1.7 has no TTL, so a
  review sandbox's lease (`HalC2.OpenShell.Review`) ends on time while the MC is
  down too. Its units are this home's like the gateway's, and `owned/0` checks them
  the same way. They carry this home's directories, and `--root` names its
  OpenShell directory, which the reaper refuses to run without reaching.

  The service manager is driven through the same seams as `HalC2.Service`
  (`:systemctl_command`, `:launchctl_command`, `:service_platform`,
  `:service_user_home` in the app env).
  """

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Config
  alias HalC2.Service

  @doc """
  This home's gateway service: its systemd unit or its launchd label, under
  `instance` (`HalC2.OpenShell.instance/0`).
  """
  def name(manager, instance \\ OpenShell.instance())
  def name(:systemd, instance), do: "hal-c2-openshell-#{instance}.service"
  def name(:launchd, instance), do: "io.github.halc2.openshell.#{instance}"

  @doc """
  This home's reaper, named beside its gateway: its systemd service (`:systemd`)
  and timer (`:timer`), or its launchd label.
  """
  def reap_name(kind, instance \\ OpenShell.instance())
  def reap_name(:systemd, instance), do: "hal-c2-openshell-#{instance}-reap.service"
  def reap_name(:timer, instance), do: "hal-c2-openshell-#{instance}-reap.timer"
  def reap_name(:launchd, instance), do: "io.github.halc2.openshell.#{instance}.reap"

  def manager, do: Service.manager()

  def unit_path(manager, instance \\ OpenShell.instance())

  def unit_path(:systemd, instance),
    do: Path.join([Service.user_home(), ".config", "systemd", "user", name(:systemd, instance)])

  def unit_path(:launchd, instance),
    do:
      Path.join([
        Service.user_home(),
        "Library",
        "LaunchAgents",
        name(:launchd, instance) <> ".plist"
      ])

  @doc """
  `:ok` unless `state` (`HalC2.OpenShell.state/0`) was installed as a service under
  another instance than this home's now, and that service is still there: its unit
  or its reaper's exists, or it runs. The home moved, or is reached through a bind mount, and acting
  under this name would leave that gateway running on the same files.
  """
  def moved(%{"mode" => "managed", "instance" => recorded}) when is_binary(recorded) do
    manager = manager()

    if manager != nil and recorded != OpenShell.instance() and
         (Enum.any?(
            [unit_path(manager, recorded) | reaper_paths(manager, recorded)],
            &File.exists?/1
          ) or
            running?(manager, recorded)),
       do:
         {:error,
          "[home-moved] OpenShell was installed when this HAL-C2 home was at another path, and its gateway's service #{name(manager, recorded)} (#{unit_path(manager, recorded)}) or its reaper (#{reap_name(if(manager == :systemd, do: :timer, else: :launchd), recorded)}) is still there. Stop and remove them, or run the MC from the path it was installed at, then try again."},
       else: :ok
  end

  def moved(_state), do: :ok

  @doc "The reaper's units, `[{path, contents}]`, that `install/1` writes beside the gateway's."
  def reaper(manager),
    do: Enum.zip_with(reaper_paths(manager), reaper_units(manager), fn p, u -> {p, u} end)

  @doc """
  `:ok` if this home's reaper is installed: each of its units is there, and this
  home's (`owned/0`). Only it ends a review sandbox's lease while the MC is down, so
  `HalC2.OpenShell.Review` opens none without it. A gateway the user runs
  (`HalC2.OpenShell.Install.reuse/2`) or a dev run's has none.
  """
  def reaped do
    with {:ok, manager} <- fetch_manager(),
         :ok <- owned() do
      if Enum.all?(reaper_paths(manager), &File.exists?/1),
        do: :ok,
        else:
          {:error,
           "Review sandboxes need this HAL-C2 home's reaper, which deletes a review's sandbox on time even while the MC is down, and it is not installed. Run `hal-c2-service openshell install` to run OpenShell as a service with its reaper."}
    end
  end

  @doc "The paths of `reaper/1`'s units."
  def reaper_paths(manager, instance \\ OpenShell.instance())

  def reaper_paths(:systemd, instance) do
    dir = Path.dirname(unit_path(:systemd, instance))
    [Path.join(dir, reap_name(:systemd, instance)), Path.join(dir, reap_name(:timer, instance))]
  end

  def reaper_paths(:launchd, instance),
    do: [
      Path.join([
        Service.user_home(),
        "Library",
        "LaunchAgents",
        reap_name(:launchd, instance) <> ".plist"
      ])
    ]

  defp reaper_units(:systemd), do: [render_reaper(:systemd), timer()]
  defp reaper_units(:launchd), do: [render_reaper(:launchd)]

  @doc """
  `:ok` unless a unit at one of this home's paths, the gateway's or the reaper's,
  was written by another home: it does not name `HalC2.OpenShell.root/0` as this
  home writes it. A missing unit, or no service manager, is `:ok`.
  """
  def owned do
    case manager() do
      nil ->
        :ok

      manager ->
        ([{unit_path(manager), home_line(manager), "gateway"}] ++
           for(path <- reaper_paths(manager), do: {path, reap_home_line(manager), "reaper"}))
        |> Enum.reduce_while(:ok, fn {path, line, what}, :ok ->
          case owned(path, line, what) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
    end
  end

  # Only this home's units in the user's own service directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp owned(path, line, what) do
    case File.read(path) do
      {:ok, text} ->
        if String.contains?(text, line),
          do: :ok,
          else:
            {:error,
             "[unit-not-ours] #{path} was not written by this HAL-C2 home (#{OpenShell.root()}): it runs another home's #{what}, so it was left alone. If no HAL-C2 home uses it, remove it, then try again."}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  # The line of the unit `render/2` writes that names this home's directory.
  defp home_line(:systemd),
    do: "\nWorkingDirectory=#{Service.unit_value(OpenShell.root(), :path)}\n"

  defp home_line(:launchd),
    do: "\n  <key>WorkingDirectory</key>\n  <string>#{xml(OpenShell.root())}</string>\n"

  # The line each of the reaper's units carries that names this home's directory:
  # a comment in a systemd unit, the `--root` argument in the launchd agent.
  defp reap_home_line(:systemd), do: reap_comment() <> "\n"

  defp reap_home_line(:launchd),
    do: "\n    <string>--root</string>\n    <string>#{xml(OpenShell.root())}</string>\n"

  defp reap_comment,
    do: "# The reaper of the HAL-C2 home at #{Service.unit_value(OpenShell.root(), :env)}"

  defp xml(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc """
  `%{"installed", "foreign", "running", "current", "unitPath"}` for the gateway's
  unit: whether it exists, whether another home wrote it (`owned/0`), whether the
  service manager says it runs, and whether it is the one `render/2` writes for
  `state` now. A foreign unit is never running or current.
  """
  # Only the gateway's unit in the user's own service directory.
  # sobelow_skip ["Traversal.FileModule"]
  def status(state) do
    case manager() do
      nil ->
        %{"installed" => false, "running" => false, "current" => false}

      manager ->
        path = unit_path(manager)
        installed = File.exists?(path)
        ours = installed and owned() == :ok

        %{
          "installed" => installed,
          "foreign" => installed and not ours,
          "running" => ours and running?(manager),
          "current" =>
            ours and state != nil and File.read(path) == {:ok, render(manager, state)} and
              Enum.all?(reaper(manager), fn {path, unit} -> File.read(path) == {:ok, unit} end),
          "unitPath" => path
        }
    end
  end

  @doc """
  Stops the reaper and the gateway, writes their units for `state`
  (`HalC2.OpenShell.state/0`) and starts them. No unit is written unless both
  stopped, so a failed stop leaves the old ones to start at the next login.
  """
  # Only the gateway's unit and log directory, under the user's own home.
  # sobelow_skip ["Traversal.FileModule"]
  def install(state) do
    with {:ok, manager} <- fetch_manager(),
         :ok <- owned(),
         :ok <- Service.prerequisites(manager),
         :ok <- halt(manager) do
      path = unit_path(manager)
      File.mkdir_p!(Path.dirname(path))
      File.mkdir_p!(Path.dirname(OpenShell.log_path()))

      with :ok <- HalC2.Paths.write_replace(path, render(manager, state), 0o644),
           :ok <- write_reaper(manager),
           do: load(manager, path)
    end
  end

  # The reaper's units, each replaced whole like the gateway's.
  defp write_reaper(manager) do
    Enum.reduce_while(reaper(manager), :ok, fn {path, unit}, :ok ->
      case HalC2.Paths.write_replace(path, unit, 0o644) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Stops the reaper and then the gateway, leaving their units in place to start
  again. `:ok` once both are stopped, or the service manager has no such unit or
  agent; any other failure is an error, and the gateway may still run (it does when
  the reaper is what did not stop).
  """
  def stop, do: with({:ok, manager} <- fetch_manager(), :ok <- owned(), do: halt(manager))

  @doc "Starts the installed unit again."
  def start do
    with {:ok, manager} <- fetch_manager(),
         :ok <- owned(),
         do: activate(manager, unit_path(manager))
  end

  @doc """
  Stops the reaper and the gateway and removes their units. Its files stay until
  the install is removed. The services are stopped whether or not their unit files
  are still there, and nothing is removed unless both stopped.
  """
  # Only the gateway's unit in the user's own service directory.
  # sobelow_skip ["Traversal.FileModule"]
  def uninstall do
    with {:ok, manager} <- fetch_manager(),
         :ok <- owned(),
         :ok <- halt(manager),
         :ok <- disable_reaper(manager) do
      path = unit_path(manager)
      for path <- reaper_paths(manager), do: File.rm(path)

      cond do
        not File.exists?(path) ->
          :ok

        manager == :systemd ->
          with :ok <- Service.run_all([{"systemctl", ["--user", "disable", name(:systemd)]}]) do
            File.rm!(path)
            Service.run_all([{"systemctl", ["--user", "daemon-reload"]}])
          end

        true ->
          File.rm!(path)
      end
    end
  end

  # What stop, start, install and uninstall all wait on before they change a file.
  # The reaper goes first, so one that does not stop leaves the gateway running; a
  # gateway that then does not stop gets its reaper back. Only a unit or agent the
  # service manager does not have counts as stopped without stopping it; the exit
  # status says which failure it was.
  defp halt(manager) do
    with :ok <- shutdown_reaper(manager) do
      case shutdown(manager) do
        :ok -> :ok
        error -> resumed(error, manager)
      end
    end
  end

  # `error`, with why the reaper did not start again if it did not: a gateway that
  # still runs keeps its reaper.
  defp resumed({:error, why} = error, manager) do
    case resume_reaper(manager) do
      :ok -> error
      {:error, other} -> {:error, "#{why}; the reaper did not start again: #{other}"}
    end
  end

  # Starts the reaper's units as they are on disk, if they are.
  defp resume_reaper(:systemd) do
    [_service, timer] = reaper_paths(:systemd)

    if File.exists?(timer),
      do: Service.run_all([{"systemctl", ["--user", "start", reap_name(:timer)]}]),
      else: :ok
  end

  defp resume_reaper(:launchd) do
    [plist] = reaper_paths(:launchd)

    if File.exists?(plist),
      do: Service.run_all([{"launchctl", ["bootstrap", "gui/#{Service.uid()}", plist]}]),
      else: :ok
  end

  defp shutdown(:systemd), do: stop_unit(name(:systemd))
  defp shutdown(:launchd), do: bootout(name(:launchd))

  # The reaper, timer first so it starts no run while its service stops. A service
  # that then does not stop gets its timer back, as the gateway still runs.
  defp shutdown_reaper(:systemd) do
    with :ok <- stop_unit(reap_name(:timer)) do
      case stop_unit(reap_name(:systemd)) do
        :ok -> :ok
        error -> resumed(error, :systemd)
      end
    end
  end

  defp shutdown_reaper(:launchd), do: bootout(reap_name(:launchd))

  defp disable_reaper(:systemd) do
    if Enum.any?(reaper_paths(:systemd), &File.exists?/1),
      do: Service.run_all([{"systemctl", ["--user", "disable", reap_name(:timer)]}]),
      else: :ok
  end

  defp disable_reaper(:launchd), do: :ok

  defp stop_unit(unit) do
    args = ["--user", "stop", unit]

    case Service.command("systemctl", args) do
      {:exit, 0, _} -> :ok
      # `systemctl stop` exits 5 ("Unit … not loaded.") for a unit it has no file
      # for and does not run: it was asked for a unit it does not have.
      {:exit, 5, _} -> :ok
      {:exit, _, out} -> {:error, Service.failure("systemctl", args, out)}
      error -> error
    end
  end

  defp bootout(label) do
    target = "gui/#{Service.uid()}/#{label}"
    args = ["bootout", target]

    case Service.command("launchctl", args) do
      {:exit, 0, _} ->
        :ok

      # launchctl exits with the errno it failed on: ESRCH (3, "No such process") for
      # an agent the domain does not have; some releases answer 113 ("Could not find
      # service"). Any other status (EIO, EINPROGRESS for one still exiting, a domain
      # it cannot reach) is an agent that may still run. `print` has to agree.
      {:exit, code, out} when code in [3, 113] ->
        if Service.probe("launchctl", ["print", target]) != :error,
          do: {:error, Service.failure("launchctl", args, out)},
          else: :ok

      {:exit, _, out} ->
        {:error, Service.failure("launchctl", args, out)}

      error ->
        error
    end
  end

  defp fetch_manager do
    case manager() do
      nil -> {:error, unsupported()}
      manager -> {:ok, manager}
    end
  end

  defp unsupported, do: "OpenShell runs as a service on Linux (systemd) and macOS only."

  defp running?(manager, instance \\ OpenShell.instance())

  defp running?(:systemd, instance),
    do: Service.probe("systemctl", ["--user", "is-active", name(:systemd, instance)]) != :error

  defp running?(:launchd, instance),
    do: Service.probe("launchctl", ["print", target(instance)]) != :error

  defp target(instance),
    do: "gui/#{Service.uid()}/#{name(:launchd, instance)}"

  # launchd bootstraps only an agent it does not have loaded.
  defp activate(:systemd, path), do: load(:systemd, path)

  defp activate(:launchd, path), do: with(:ok <- halt(:launchd), do: load(:launchd, path))

  # Starts the unit at `path` as it is on disk. Every step runs, so a gateway that
  # does not start still gets its reaper: one that comes up later has its leases
  # enforced, and leases left on it are reaped.
  defp load(:systemd, _path) do
    run_each([
      {"systemctl", ["--user", "daemon-reload"]},
      {"systemctl", ["--user", "enable", name(:systemd)]},
      {"systemctl", ["--user", "restart", name(:systemd)]},
      {"systemctl", ["--user", "enable", "--now", reap_name(:timer)]}
    ])
  end

  defp load(:launchd, path) do
    [{reap_path, _}] = reaper(:launchd)

    run_each([
      {"launchctl", ["bootstrap", "gui/#{Service.uid()}", path]},
      {"launchctl", ["bootstrap", "gui/#{Service.uid()}", reap_path]}
    ])
  end

  # Runs every step, failed or not: `:ok`, or an error naming each that failed.
  defp run_each(steps) do
    failures =
      for {exe, args} <- steps,
          failure = step_failure(exe, args),
          do: failure

    if failures == [], do: :ok, else: {:error, Enum.join(failures, "; ")}
  end

  defp step_failure(exe, args) do
    case Service.command(exe, args) do
      {:exit, 0, _} -> nil
      {:exit, _, out} -> Service.failure(exe, args, out)
      {:error, why} -> why
    end
  end

  # `hal-c2-service openshell reap` from a release, `mix hal_c2.openshell reap` in
  # this checkout otherwise, with the MC's home: units get neither PATH nor a shell.
  # `--root` is this home's OpenShell directory, which the reaper checks it reaches.
  defp reap_program do
    reap = ["reap", "--root", OpenShell.root()]

    case System.get_env("RELEASE_ROOT") do
      nil ->
        {[System.find_executable("mix") || "mix", "hal_c2.openshell" | reap], File.cwd!()}

      root ->
        {[Path.join([root, "bin", "hal-c2-service"]), "openshell" | reap], Service.user_home()}
    end
  end

  @xdg [
    {"XDG_CONFIG_HOME", [".config"]},
    {"XDG_DATA_HOME", [".local", "share"]},
    {"XDG_STATE_HOME", [".local", "state"]},
    {"XDG_CACHE_HOME", [".cache"]}
  ]

  # What decides this home's directories (`HalC2.Paths`): the home variables the
  # user chose and each XDG base as this process resolves it, so neither the
  # service manager's environment nor a missing override moves the reaper elsewhere.
  @doc false
  def reap_env do
    home = HalC2.Paths.user_home()

    xdg =
      for {name, default} <- @xdg,
          do:
            {name,
             HalC2.Paths.absolute(System.get_env(name), :unix) || Path.join([home | default])}

    [{"PATH", System.get_env("PATH", "")} | Service.chosen_home()] ++ xdg
  end

  defp render_reaper(:systemd) do
    {argv, cwd} = reap_program()
    log = Service.unit_value(OpenShell.log_path(), :path)

    Enum.join(
      List.flatten([
        reap_comment(),
        "[Unit]",
        "Description=Deletes HAL-C2 review sandboxes past their time",
        # It asks the gateway, so at boot it runs after the gateway's unit, itself
        # after its runtime; ordering only, as a reap must not start either.
        "After=#{name(:systemd)}",
        "",
        "[Service]",
        "Type=oneshot",
        "WorkingDirectory=#{Service.unit_value(cwd, :path)}",
        for(
          {name, value} <- reap_env(),
          do: "Environment=#{name}=#{Service.unit_value(value, :env)}"
        ),
        "ExecStart=#{Enum.map_join(argv, " ", &Service.unit_value(&1, :exec))}",
        "UMask=0077",
        "NoNewPrivileges=yes",
        "StandardOutput=append:#{log}",
        "StandardError=append:#{log}",
        ""
      ]),
      "\n"
    )
  end

  defp render_reaper(:launchd) do
    {argv, cwd} = reap_program()
    x = &escape/1
    log = x.(OpenShell.log_path())

    env =
      Enum.map_join(reap_env(), "\n", fn {k, v} ->
        "    <key>#{k}</key>\n    <string>#{x.(v)}</string>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{reap_name(:launchd)}</string>
      <key>ProgramArguments</key>
      <array>
    #{Enum.map_join(argv, "\n", &"    <string>#{x.(&1)}</string>")}
      </array>
      <key>EnvironmentVariables</key>
      <dict>
    #{env}
      </dict>
      <key>WorkingDirectory</key>
      <string>#{x.(cwd)}</string>
      <key>Umask</key>
      <integer>63</integer>
      <key>RunAtLoad</key>
      <true/>
      <key>StartInterval</key>
      <integer>60</integer>
      <key>StandardOutPath</key>
      <string>#{log}</string>
      <key>StandardErrorPath</key>
      <string>#{log}</string>
    </dict>
    </plist>
    """
  end

  defp timer do
    Enum.join(
      [
        reap_comment(),
        "[Unit]",
        "Description=Deletes HAL-C2 review sandboxes past their time, every minute",
        "",
        "[Timer]",
        "OnBootSec=1min",
        "OnUnitActiveSec=1min",
        "AccuracySec=10s",
        "",
        "[Install]",
        "WantedBy=timers.target",
        ""
      ],
      "\n"
    )
  end

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc "The unit `install/1` writes for `state`."
  def render(:systemd, state) do
    log = Service.unit_value(OpenShell.log_path(), :path)
    argv = Config.command(OpenShell.gateway_bin(state["version"]))

    Enum.join(
      List.flatten([
        "[Unit]",
        "Description=NVIDIA OpenShell gateway for HAL-C2",
        # The runtime the gateway's driver dials (Linux runs Podman only,
        # `HalC2.OpenShell.Platform`), so at boot the gateway does not spend its
        # restarts on it.
        "Wants=podman.socket",
        "After=podman.socket",
        "StartLimitIntervalSec=300",
        "StartLimitBurst=5",
        "",
        "[Service]",
        "Type=simple",
        "WorkingDirectory=#{Service.unit_value(OpenShell.root(), :path)}",
        "ExecStart=#{Enum.map_join(argv, " ", &Service.unit_value(&1, :exec))}",
        "UMask=0077",
        "NoNewPrivileges=yes",
        "Restart=on-failure",
        "RestartSec=5",
        "StandardOutput=append:#{log}",
        "StandardError=append:#{log}",
        "",
        "[Install]",
        "WantedBy=default.target",
        ""
      ]),
      "\n"
    )
  end

  def render(:launchd, state) do
    x = &xml/1

    argv = Config.command(OpenShell.gateway_bin(state["version"]))
    log = x.(OpenShell.log_path())

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{name(:launchd)}</string>
      <key>ProgramArguments</key>
      <array>
    #{Enum.map_join(argv, "\n", &"    <string>#{x.(&1)}</string>")}
      </array>
      <key>WorkingDirectory</key>
      <string>#{x.(OpenShell.root())}</string>
      <key>Umask</key>
      <integer>63</integer>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <dict>
        <key>SuccessfulExit</key>
        <false/>
      </dict>
      <key>ThrottleInterval</key>
      <integer>5</integer>
      <key>StandardOutPath</key>
      <string>#{log}</string>
      <key>StandardErrorPath</key>
      <string>#{log}</string>
    </dict>
    </plist>
    """
  end
end
