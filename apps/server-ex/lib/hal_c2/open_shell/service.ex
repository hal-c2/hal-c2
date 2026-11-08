defmodule HalC2.OpenShell.Service do
  @moduledoc """
  The OpenShell gateway as a service of its own: a systemd user unit on Linux
  (`hal-c2-openshell.service`), a LaunchAgent on macOS (`io.github.halc2.openshell`).
  It is not part of the MC's unit, so the gateway and its sandboxes outlive an MC
  restart or crash, and the MC never holds the runtime socket itself.

  The unit pins the gateway's environment (`HalC2.OpenShell.Config.environment/0`)
  and, under systemd, unsets every variable that could switch its telemetry or
  auth back on; a LaunchAgent starts with launchd's own environment, not the
  user's shell, so it inherits none of them.

  The service manager is driven through the same seams as `HalC2.Service`
  (`:systemctl_command`, `:launchctl_command`, `:service_platform`,
  `:service_user_home` in the app env).
  """

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Config
  alias HalC2.Service

  @unit "hal-c2-openshell.service"
  @label "io.github.halc2.openshell"

  def name(:systemd), do: @unit
  def name(:launchd), do: @label

  def manager, do: Service.manager()

  def unit_path(:systemd),
    do: Path.join([Service.user_home(), ".config", "systemd", "user", @unit])

  def unit_path(:launchd),
    do: Path.join([Service.user_home(), "Library", "LaunchAgents", @label <> ".plist"])

  @doc """
  `%{"installed", "running", "current", "unitPath"}` for the gateway's unit:
  whether it exists, whether the service manager says it runs, and whether it is the
  one `render/2` writes for `state` now.
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

        %{
          "installed" => installed,
          "running" => installed and running?(manager),
          "current" =>
            installed and state != nil and File.read(path) == {:ok, render(manager, state)},
          "unitPath" => path
        }
    end
  end

  @doc "Writes the unit for `state` (`HalC2.OpenShell.state/0`) and (re)starts it."
  # Only the gateway's unit and log directory, under the user's own home.
  # sobelow_skip ["Traversal.FileModule"]
  def install(state) do
    with {:ok, manager} <- fetch_manager(),
         :ok <- prerequisites(manager) do
      path = unit_path(manager)
      File.mkdir_p!(Path.dirname(path))
      File.mkdir_p!(Path.dirname(OpenShell.log_path()))
      File.write!(path, render(manager, state))
      Service.run_all(activate(manager, path))
    end
  end

  @doc "Stops the gateway, leaving the unit in place to start again."
  def stop do
    case manager() do
      :systemd -> Service.run_all([{"systemctl", ["--user", "stop", @unit]}])
      :launchd -> Service.run_all([{"launchctl", ["bootout", target()], :ignore}])
      nil -> {:error, unsupported()}
    end
  end

  @doc "Starts the installed unit again."
  def start do
    case manager() do
      nil -> {:error, unsupported()}
      manager -> Service.run_all(activate(manager, unit_path(manager)))
    end
  end

  @doc "Stops the gateway and removes its unit. Its files stay until the install is removed."
  # Only the gateway's unit in the user's own service directory.
  # sobelow_skip ["Traversal.FileModule"]
  def uninstall do
    with {:ok, manager} <- fetch_manager() do
      path = unit_path(manager)

      if File.exists?(path) do
        with :ok <- Service.run_all(deactivate(manager)) do
          File.rm!(path)

          if manager == :systemd,
            do: Service.run_all([{"systemctl", ["--user", "daemon-reload"]}]),
            else: :ok
        end
      else
        :ok
      end
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
    do: Service.probe("systemctl", ["--user", "is-active", @unit]) != :error

  defp running?(:launchd), do: Service.probe("launchctl", ["print", target()]) != :error

  defp target, do: "gui/#{Service.uid()}/#{@label}"

  defp activate(:systemd, _path) do
    [
      {"systemctl", ["--user", "daemon-reload"]},
      {"systemctl", ["--user", "enable", @unit]},
      {"systemctl", ["--user", "restart", @unit]}
    ]
  end

  defp activate(:launchd, path) do
    [
      {"launchctl", ["bootout", target()], :ignore},
      {"launchctl", ["bootstrap", "gui/#{Service.uid()}", path]}
    ]
  end

  defp deactivate(:systemd), do: [{"systemctl", ["--user", "disable", "--now", @unit]}]
  defp deactivate(:launchd), do: [{"launchctl", ["bootout", target()], :ignore}]

  @doc "The unit `install/1` writes for `state`."
  def render(:systemd, state) do
    q = &Service.quote_value/1
    log = OpenShell.log_path()
    argv = [OpenShell.gateway_bin(state["version"]) | Config.args()]
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
        "UnsetEnvironment=#{Enum.join(Config.unset_environment(), " ")}",
        for({k, v} <- Config.environment(), do: "Environment=#{k}=#{q.(v)}"),
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
    x =
      &(&1
        |> String.replace("&", "&amp;")
        |> String.replace("<", "&lt;")
        |> String.replace(">", "&gt;"))

    argv = [OpenShell.gateway_bin(state["version"]) | Config.args()]
    log = x.(OpenShell.log_path())

    env =
      Enum.map_join(Config.environment(), "\n", fn {k, v} ->
        "    <key>#{k}</key>\n    <string>#{x.(v)}</string>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{@label}</string>
      <key>ProgramArguments</key>
      <array>
    #{Enum.map_join(argv, "\n", &"    <string>#{x.(&1)}</string>")}
      </array>
      <key>EnvironmentVariables</key>
      <dict>
    #{env}
      </dict>
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
