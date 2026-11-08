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

  @doc "This home's gateway service: its systemd unit or its launchd label."
  def name(:systemd), do: "hal-c2-openshell-#{OpenShell.instance()}.service"
  def name(:launchd), do: "io.github.halc2.openshell.#{OpenShell.instance()}"

  @doc """
  This home's reaper, named beside its gateway: its systemd service (`:systemd`)
  and timer (`:timer`), or its launchd label.
  """
  def reap_name(:systemd), do: "hal-c2-openshell-#{OpenShell.instance()}-reap.service"
  def reap_name(:timer), do: "hal-c2-openshell-#{OpenShell.instance()}-reap.timer"
  def reap_name(:launchd), do: "io.github.halc2.openshell.#{OpenShell.instance()}.reap"

  def manager, do: Service.manager()

  def unit_path(:systemd),
    do: Path.join([Service.user_home(), ".config", "systemd", "user", name(:systemd)])

  def unit_path(:launchd),
    do: Path.join([Service.user_home(), "Library", "LaunchAgents", name(:launchd) <> ".plist"])

  @doc "The reaper's units, `[{path, contents}]`, that `install/1` writes beside the gateway's."
  def reaper(manager),
    do: Enum.zip_with(reaper_paths(manager), reaper_units(manager), fn p, u -> {p, u} end)

  @doc "The paths of `reaper/1`'s units."
  def reaper_paths(:systemd) do
    dir = Path.dirname(unit_path(:systemd))
    [Path.join(dir, reap_name(:systemd)), Path.join(dir, reap_name(:timer))]
  end

  def reaper_paths(:launchd),
    do: [
      Path.join([Service.user_home(), "Library", "LaunchAgents", reap_name(:launchd) <> ".plist"])
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
  defp home_line(:systemd), do: "\nWorkingDirectory=#{Service.quote_value(OpenShell.root())}\n"

  defp home_line(:launchd),
    do: "\n  <key>WorkingDirectory</key>\n  <string>#{xml(OpenShell.root())}</string>\n"

  # The line each of the reaper's units carries that names this home's directory:
  # a comment in a systemd unit, the `--root` argument in the launchd agent.
  defp reap_home_line(:systemd), do: reap_comment() <> "\n"

  defp reap_home_line(:launchd),
    do: "\n    <string>--root</string>\n    <string>#{xml(OpenShell.root())}</string>\n"

  defp reap_comment,
    do: "# The reaper of the HAL-C2 home at #{Service.quote_value(OpenShell.root())}"

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

  @doc "Writes the unit for `state` (`HalC2.OpenShell.state/0`) and (re)starts it."
  # Only the gateway's unit and log directory, under the user's own home.
  # sobelow_skip ["Traversal.FileModule"]
  def install(state) do
    with {:ok, manager} <- fetch_manager(),
         :ok <- owned(),
         :ok <- prerequisites(manager) do
      path = unit_path(manager)
      File.mkdir_p!(Path.dirname(path))
      File.mkdir_p!(Path.dirname(OpenShell.log_path()))
      File.write!(path, render(manager, state))
      for {path, unit} <- reaper(manager), do: File.write!(path, unit)
      activate(manager, path)
    end
  end

  @doc """
  Stops the gateway, leaving the unit in place to start again. `:ok` once it is
  stopped, or the service manager has no such unit or agent; any other failure is
  an error, and the gateway may still run.
  """
  def stop, do: with({:ok, manager} <- fetch_manager(), :ok <- owned(), do: shutdown(manager))

  @doc "Starts the installed unit again."
  def start do
    with {:ok, manager} <- fetch_manager(),
         :ok <- owned(),
         do: activate(manager, unit_path(manager))
  end

  @doc """
  Stops the gateway and removes its unit. Its files stay until the install is
  removed. The service is stopped whether or not its unit file is still there, and
  nothing is removed unless it stopped.
  """
  # Only the gateway's unit in the user's own service directory.
  # sobelow_skip ["Traversal.FileModule"]
  def uninstall do
    with {:ok, manager} <- fetch_manager(),
         :ok <- owned(),
         :ok <- shutdown(manager) do
      path = unit_path(manager)

      # The reaper goes first: it has nothing to reap without the gateway.
      Service.run_all(stop_reaper(manager))
      for {path, _} <- reaper(manager), do: File.rm(path)

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
  # Only a unit or agent the service manager does not have counts as stopped
  # without stopping it; the exit status says which failure it was.
  defp shutdown(:systemd) do
    args = ["--user", "stop", name(:systemd)]

    case Service.command("systemctl", args) do
      {:exit, 0, _} -> :ok
      # `systemctl stop` exits 5 ("Unit … not loaded.") for a unit it has no file
      # for and does not run: it was asked for a unit it does not have.
      {:exit, 5, _} -> :ok
      {:exit, _, out} -> {:error, Service.failure("systemctl", args, out)}
      error -> error
    end
  end

  defp shutdown(:launchd) do
    args = ["bootout", target()]

    case Service.command("launchctl", args) do
      {:exit, 0, _} ->
        :ok

      # launchctl exits with the errno it failed on: ESRCH (3, "No such process") for
      # an agent the domain does not have; some releases answer 113 ("Could not find
      # service"). Any other status (EIO, EINPROGRESS for one still exiting, a domain
      # it cannot reach) is a gateway that may still run. `print` has to agree.
      {:exit, code, out} when code in [3, 113] ->
        if running?(:launchd), do: {:error, Service.failure("launchctl", args, out)}, else: :ok

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

  defp prerequisites(:launchd), do: :ok

  defp prerequisites(:systemd) do
    if Service.probe("systemctl", ["--user", "show-environment"]) == :error,
      do:
        {:error,
         "[user-manager-unavailable] #{Service.problem_message("user-manager-unavailable")}"},
      else: :ok
  end

  defp running?(:systemd),
    do: Service.probe("systemctl", ["--user", "is-active", name(:systemd)]) != :error

  defp running?(:launchd), do: Service.probe("launchctl", ["print", target()]) != :error

  defp target, do: "gui/#{Service.uid()}/#{name(:launchd)}"

  defp activate(:systemd, _path) do
    Service.run_all([
      {"systemctl", ["--user", "daemon-reload"]},
      {"systemctl", ["--user", "enable", name(:systemd)]},
      {"systemctl", ["--user", "restart", name(:systemd)]},
      {"systemctl", ["--user", "enable", "--now", reap_name(:timer)]}
    ])
  end

  defp activate(:launchd, path) do
    [{reap_path, _}] = reaper(:launchd)

    with :ok <- shutdown(:launchd) do
      Service.run_all([
        {"launchctl", ["bootstrap", "gui/#{Service.uid()}", path]},
        {"launchctl", ["bootout", reap_target()], :ignore},
        {"launchctl", ["bootstrap", "gui/#{Service.uid()}", reap_path]}
      ])
    end
  end

  defp stop_reaper(:systemd),
    do: [{"systemctl", ["--user", "disable", "--now", reap_name(:timer)], :ignore}]

  defp stop_reaper(:launchd), do: [{"launchctl", ["bootout", reap_target()], :ignore}]

  defp reap_target, do: "gui/#{Service.uid()}/#{reap_name(:launchd)}"

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
    q = &Service.quote_value/1
    {argv, cwd} = reap_program()
    log = OpenShell.log_path()

    Enum.join(
      List.flatten([
        reap_comment(),
        "[Unit]",
        "Description=Deletes HAL-C2 review sandboxes past their time",
        "",
        "[Service]",
        "Type=oneshot",
        "WorkingDirectory=#{q.(cwd)}",
        for({name, value} <- reap_env(), do: "Environment=#{name}=#{q.(value)}"),
        "ExecStart=#{Enum.map_join(argv, " ", q)}",
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
    q = &Service.quote_value/1
    log = OpenShell.log_path()
    argv = Config.command(OpenShell.gateway_bin(state["version"]))
    podman = state["driver"] == "podman"

    Enum.join(
      List.flatten([
        "[Unit]",
        "Description=NVIDIA OpenShell gateway for HAL-C2",
        if(podman, do: ["Wants=podman.socket", "After=podman.socket"], else: []),
        "StartLimitIntervalSec=300",
        "StartLimitBurst=5",
        "",
        "[Service]",
        "Type=simple",
        "WorkingDirectory=#{q.(OpenShell.root())}",
        "ExecStart=#{Enum.map_join(argv, " ", q)}",
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
