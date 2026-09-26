defmodule T3.Service do
  @moduledoc """
  Installs a release as a background service for the user, as the Node server's
  `t3 service install|status|uninstall` does (apps/server/src/cloud/bootService.ts):
  a systemd user unit on Linux, a launch agent on macOS. The service runs
  `bin/t3-service`, which starts the node again when it exits into an update.

  Reached from a release with `bin/t3-service install|status|uninstall`.
  """

  @unit "t3-node.service"
  @label "com.t3tools.t3node.service"

  @doc "Runs a `bin/t3-service` subcommand and prints its outcome; exits 1 on failure."
  def main([command]) when command in ~w(install status uninstall) do
    result =
      case command do
        "install" -> install()
        "uninstall" -> uninstall()
        "status" -> {:ok, status()}
      end

    case result do
      {:ok, info} ->
        IO.puts(format(command, info))

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  def main(_), do: IO.puts(:stderr, "usage: t3-service [install|status|uninstall]")

  @doc """
  Writes the unit (or plist) for this release, then registers, enables and starts
  it. Running it again repairs an installed service.
  """
  def install do
    with {:ok, root} <- release_root(),
         {:ok, manager} <- manager() do
      path = unit_path(manager)
      File.mkdir_p!(Path.dirname(path))
      File.mkdir_p!(Path.dirname(log_path()))
      File.write!(path, render(manager, Path.join([root, "bin", "t3-service"])))

      with :ok <- steps(manager, :install) do
        {:ok, status()}
      end
    end
  end

  @doc "Stops the service and removes it from startup; the T3 home is left intact."
  def uninstall do
    with {:ok, manager} <- manager() do
      :ok = steps(manager, :uninstall)
      File.rm(unit_path(manager))
      if manager == :systemd, do: run("systemctl", ["--user", "daemon-reload"])
      {:ok, status()}
    end
  end

  @doc """
  `%{"manager", "installed", "enabled", "active", "unitPath", "logPath"}` for this
  user's service; `"linger"` too under systemd, whether it outlives logout.
  """
  def status do
    case manager() do
      {:ok, :systemd} ->
        user = System.get_env("USER") || "root"

        %{
          "manager" => "systemd",
          "installed" => File.exists?(unit_path(:systemd)),
          "enabled" => ok?("systemctl", ["--user", "is-enabled", @unit]),
          "active" => ok?("systemctl", ["--user", "is-active", @unit]),
          "linger" =>
            match?(
              {"Linger=yes" <> _, 0},
              run("loginctl", ["show-user", user, "--property=Linger"])
            ),
          "unitPath" => unit_path(:systemd),
          "logPath" => log_path()
        }

      {:ok, :launchd} ->
        installed = File.exists?(unit_path(:launchd))

        %{
          "manager" => "launchd",
          "installed" => installed,
          "enabled" => installed,
          "active" => ok?("launchctl", ["print", target()]),
          "unitPath" => unit_path(:launchd),
          "logPath" => log_path()
        }

      {:error, message} ->
        %{"manager" => nil, "installed" => false, "error" => message}
    end
  end

  # Enable before start; lingering is best effort, as it may need an administrator.
  defp steps(:systemd, :install) do
    with :ok <- step("systemctl", ["--user", "daemon-reload"]),
         :ok <- step("systemctl", ["--user", "enable", @unit]),
         :ok <- step("systemctl", ["--user", "restart", @unit]) do
      run("loginctl", ["enable-linger", System.get_env("USER") || "root"])
      :ok
    end
  end

  defp steps(:systemd, :uninstall) do
    run("systemctl", ["--user", "disable", "--now", @unit])
    :ok
  end

  # Loading a RunAtLoad plist starts the job; bootout first so a reinstall reloads it.
  defp steps(:launchd, :install) do
    run("launchctl", ["bootout", target()])
    run("launchctl", ["enable", target()])
    step("launchctl", ["bootstrap", domain(), unit_path(:launchd)])
  end

  defp steps(:launchd, :uninstall) do
    run("launchctl", ["bootout", target()])
    :ok
  end

  defp render(:systemd, program) do
    """
    [Unit]
    Description=T3 node

    [Service]
    Type=simple
    WorkingDirectory=%h
    Environment=T3_HOME=#{Application.fetch_env!(:t3, :home)}
    ExecStart=#{program}
    KillMode=mixed
    OOMPolicy=continue
    Restart=always
    RestartSec=5
    StandardOutput=append:#{log_path()}
    StandardError=append:#{log_path()}

    [Install]
    WantedBy=default.target
    """
  end

  defp render(:launchd, program) do
    esc = &(&1 |> String.replace("&", "&amp;") |> String.replace("<", "&lt;"))

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{@label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{esc.(program)}</string>
      </array>
      <key>EnvironmentVariables</key>
      <dict>
        <key>T3_HOME</key>
        <string>#{esc.(Application.fetch_env!(:t3, :home))}</string>
      </dict>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
      <key>StandardOutPath</key>
      <string>#{esc.(log_path())}</string>
      <key>StandardErrorPath</key>
      <string>#{esc.(log_path())}</string>
    </dict>
    </plist>
    """
  end

  defp format("status", info), do: status_line(info)
  defp format(command, info), do: "#{command}ed. " <> status_line(info)

  defp status_line(%{"manager" => nil, "error" => error}), do: error

  defp status_line(info) do
    flags =
      for key <- ~w(installed enabled active linger),
          Map.has_key?(info, key),
          do: "#{key}=#{info[key]}"

    "#{info["manager"]} #{Enum.join(flags, " ")}\nunit: #{info["unitPath"]}\nlog: #{info["logPath"]}"
  end

  defp manager do
    case Application.get_env(:t3, :os_type, :os.type()) do
      {:unix, :linux} -> {:ok, :systemd}
      {:unix, :darwin} -> {:ok, :launchd}
      _ -> {:error, "Background services are supported on Linux (systemd) and macOS only."}
    end
  end

  defp release_root do
    case System.get_env("RELEASE_ROOT") do
      nil -> {:error, "Only a release installs as a service; run bin/t3-service install from it."}
      root -> {:ok, root}
    end
  end

  defp unit_path(:systemd), do: Path.join([user_home(), ".config", "systemd", "user", @unit])

  defp unit_path(:launchd),
    do: Path.join([user_home(), "Library", "LaunchAgents", "#{@label}.plist"])

  defp log_path, do: Path.join([Application.fetch_env!(:t3, :home), "logs", "service.log"])

  defp domain, do: "gui/#{uid()}"
  defp target, do: "#{domain()}/#{@label}"

  defp uid do
    case run("id", ["-u"]) do
      {uid, 0} -> String.trim(uid)
      _ -> "0"
    end
  end

  defp user_home, do: Application.get_env(:t3, :user_home) || System.user_home!()

  defp step(command, args) do
    case run(command, args) do
      {_, 0} ->
        :ok

      {out, status} ->
        {:error, "#{command} #{Enum.join(args, " ")} failed (#{status}): #{String.trim(out)}"}
    end
  end

  defp ok?(command, args), do: match?({_, 0}, run(command, args))

  defp run(command, args) do
    case System.find_executable(command) do
      nil -> {"#{command} not found", 127}
      exe -> System.cmd(exe, args, stderr_to_stdout: true)
    end
  end
end
